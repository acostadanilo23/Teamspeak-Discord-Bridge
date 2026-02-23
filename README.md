# TS-Bot Multi-Service Audio Bridge

Bidirectional audio bridge between TeamSpeak 3 and Discord, optimized for multi-machine deployment.

## Architecture

This project is split into 4 independent services:
- **musico-acosta**: Main music bot instance.
- **bot-discord-audio**: Dedicated relay that auto-plays Discord audio in TeamSpeak.
- **bot-discord-mic**: Rust-based TeamSpeak listener that captures voice for Discord.
- **discord-bridge**: Python bot that bridge Discord voice to/from HTTP streams.

## Setup

1. **Install Dependencies**:
   ```bash
   sudo apt update
   sudo apt install pkg-config libssl-dev cmake libopus-dev ffmpeg python3-venv
   ```

2. **Configure**:
   - Create `config.env` based on `config.env.example` (or use the one provided if local).
   - Place your Discord token in `shared/discord-token.txt`.

3. **Install Python Venv**:
   ```bash
   python3 -m venv bridge-env
   source bridge-env/bin/python3 -m pip install discord.py[voice] discord-ext-voice-recv aiohttp
   ```

4. **Build/Place Binaries**:
   Ensure `TS3AudioBot` and `ts3-listener` binaries are in the `shared/` directory.

## Management

Use the unified control script:
```bash
./ts-bridge.sh start    # Start all services
./ts-bridge.sh status   # Check status
./ts-bridge.sh stop     # Stop all
./ts-bridge.sh logs <service> # View logs
```

## License
MIT (or your preferred license)
