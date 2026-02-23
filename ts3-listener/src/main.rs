//! TS3 Voice Listener - Captures TeamSpeak voice and serves as WAV HTTP stream
//!
//! Connects to a TeamSpeak 3 server, captures all voice in the channel,
//! decodes Opus to PCM, and serves it as a WAV HTTP stream on port 8081.

use std::sync::{Arc, Mutex};
use std::net::SocketAddr;

use futures::prelude::*;
use tokio::sync::broadcast;
use tracing::{info, warn, debug, error};

use tsclientlib::{ClientId, Connection, DisconnectOptions, StreamItem};
use tsproto_packets::packets::AudioData;

const USUAL_FRAME_SIZE: usize = 960;

fn wav_header() -> Vec<u8> {
    let mut h = Vec::with_capacity(44);
    h.extend_from_slice(b"RIFF");
    h.extend_from_slice(&0xFFFFFFFFu32.to_le_bytes());
    h.extend_from_slice(b"WAVEfmt ");
    h.extend_from_slice(&16u32.to_le_bytes());
    h.extend_from_slice(&1u16.to_le_bytes());       // PCM
    h.extend_from_slice(&2u16.to_le_bytes());       // Stereo
    h.extend_from_slice(&48000u32.to_le_bytes());
    h.extend_from_slice(&(48000u32 * 2 * 2).to_le_bytes());
    h.extend_from_slice(&4u16.to_le_bytes());
    h.extend_from_slice(&16u16.to_le_bytes());
    h.extend_from_slice(b"data");
    h.extend_from_slice(&0xFFFFFFFFu32.to_le_bytes());
    h
}

type AudioHandler = tsclientlib::audio::AudioHandler<(u64, ClientId)>;

struct AppState {
    audio_handler: Mutex<AudioHandler>,
    tx: broadcast::Sender<Vec<u8>>,
}

async fn audio_pump(state: Arc<AppState>) {
    let mut interval = tokio::time::interval(std::time::Duration::from_millis(20));
    let mut float_buf = vec![0.0f32; USUAL_FRAME_SIZE * 2];

    loop {
        interval.tick().await;

        {
            let mut handler = state.audio_handler.lock().unwrap();
            for s in float_buf.iter_mut() { *s = 0.0; }
            handler.fill_buffer(&mut float_buf);
        }

        let mut pcm_bytes = Vec::with_capacity(float_buf.len() * 2);
        for &sample in &float_buf {
            let clamped = sample.max(-1.0).min(1.0);
            let i16_val = (clamped * 32767.0) as i16;
            pcm_bytes.extend_from_slice(&i16_val.to_le_bytes());
        }

        if state.tx.receiver_count() > 0 {
            let _ = state.tx.send(pcm_bytes);
        }
    }
}



#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();

    let address = std::env::var("TS3_ADDRESS").unwrap_or_else(|_| "147.15.101.89".to_string());
    let name = std::env::var("TS3_NAME").unwrap_or_else(|_| "TS3-Listener".to_string());

    info!("Connecting to TS3 server at {}", address);

    let (tx, _) = broadcast::channel::<Vec<u8>>(32);

    let state = Arc::new(AppState {
        audio_handler: Mutex::new(AudioHandler::new()),
        tx,
    });

    // Start HTTP stream server using raw TCP (simpler than hyper for infinite streaming)
    let http_state = state.clone();
    tokio::spawn(async move {
        let addr = SocketAddr::from(([0, 0, 0, 0], 8081));
        let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
        info!("HTTP stream server listening on http://0.0.0.0:8081/stream");

        loop {
            let (mut stream, peer) = match listener.accept().await {
                Ok(s) => s,
                Err(e) => { error!("Accept failed: {}", e); continue; }
            };

            let state = http_state.clone();
            tokio::spawn(async move {
                use tokio::io::AsyncWriteExt;
                use tokio::io::AsyncBufReadExt;

                // Read the HTTP request line (we don't really care about it)
                let mut reader = tokio::io::BufReader::new(&mut stream);
                let mut request_line = String::new();
                if let Err(_) = reader.read_line(&mut request_line).await {
                    return;
                }

                // Read remaining headers until empty line
                loop {
                    let mut line = String::new();
                    match reader.read_line(&mut line).await {
                        Ok(0) | Err(_) => return,
                        Ok(_) => {
                            if line.trim().is_empty() { break; }
                        }
                    }
                }

                info!("Stream client connected from {}", peer);

                // Send HTTP response header
                let http_header = format!(
                    "HTTP/1.1 200 OK\r\n\
                     Content-Type: audio/wav\r\n\
                     Connection: keep-alive\r\n\
                     Cache-Control: no-cache\r\n\
                     X-Accel-Buffering: no\r\n\
                     \r\n"
                );

                let writer = reader.into_inner();
                if let Err(_) = writer.write_all(http_header.as_bytes()).await {
                    return;
                }

                // Send WAV header
                if let Err(_) = writer.write_all(&wav_header()).await {
                    return;
                }

                // Subscribe and stream PCM
                let mut rx = state.tx.subscribe();
                loop {
                    match rx.recv().await {
                        Ok(data) => {
                            if let Err(_) = writer.write_all(&data).await {
                                debug!("Stream client {} disconnected", peer);
                                return;
                            }
                        }
                        Err(broadcast::error::RecvError::Lagged(n)) => {
                            debug!("Stream client {} lagged by {} frames", peer, n);
                        }
                        Err(broadcast::error::RecvError::Closed) => {
                            return;
                        }
                    }
                }
            });
        }
    });

    // Start audio pump
    let pump_state = state.clone();
    tokio::spawn(audio_pump(pump_state));

    // Connect to TS3
    let con_config = Connection::build(address.as_str())
        .name(name)
        .log_commands(false)
        .log_packets(false)
        .log_udp_packets(false);

    let mut con = con_config.connect()?;

    info!("Waiting for TS3 connection...");

    // Wait for connection
    let r = con
        .events()
        .try_filter(|e| future::ready(matches!(e, StreamItem::BookEvents(_))))
        .next()
        .await;
    if let Some(r) = r { r?; }

    info!("Connected to TS3! Listening for voice...");

    let con_id = 0u64;

    // Main event loop
    let mut events = con.events();
    loop {
        tokio::select! {
            event = events.try_next() => {
                match event {
                    Ok(Some(StreamItem::Audio(packet))) => {
                        let from = ClientId(match packet.data().data() {
                            AudioData::S2C { from, .. } => *from,
                            AudioData::S2CWhisper { from, .. } => *from,
                            _ => continue,
                        });
                        let mut handler = state.audio_handler.lock().unwrap();
                        if let Err(e) = handler.handle_packet((con_id, from), packet) {
                            debug!("Failed to handle audio packet: {}", e);
                        }
                    }
                    Ok(Some(_)) => {}
                    Ok(None) => {
                        warn!("TS3 event stream ended");
                        break;
                    }
                    Err(e) => {
                        error!("TS3 event error: {}", e);
                        break;
                    }
                }
            }
            _ = tokio::signal::ctrl_c() => {
                info!("Shutting down...");
                break;
            }
        }
    }

    drop(events);
    con.disconnect(DisconnectOptions::new())?;
    con.events().for_each(|_| future::ready(())).await;

    Ok(())
}
