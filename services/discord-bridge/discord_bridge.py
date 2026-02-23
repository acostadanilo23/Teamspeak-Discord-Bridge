import discord
from discord.ext import commands
from discord.ext import voice_recv
from aiohttp import web
import asyncio
import time
import struct
import os

# Read config from environment or defaults
TOKEN_FILE = os.environ.get("DISCORD_TOKEN_FILE", "/home/dan/code/ts-bot/shared/discord-token.txt")
TOKEN = open(TOKEN_FILE).read().strip()
DISCORD_STREAM_PORT = int(os.environ.get("DISCORD_STREAM_PORT", "8080"))
TS3_STREAM_PORT = int(os.environ.get("TS3_STREAM_PORT", "8081"))
TS3_STREAM_URL = f"http://localhost:{TS3_STREAM_PORT}/stream"

intents = discord.Intents.default()
intents.message_content = True
bot = commands.Bot(command_prefix="!", intents=intents)

stream_clients = []

# WAV header for the HTTP stream (PCM 16-bit, 48000Hz, Stereo)
def get_wav_header():
    header = bytearray(b'RIFF')
    header.extend(struct.pack('<I', 0xFFFFFFFF))
    header.extend(b'WAVEfmt ')
    header.extend(struct.pack('<I', 16))
    header.extend(struct.pack('<H', 1))       # PCM
    header.extend(struct.pack('<H', 2))       # Stereo
    header.extend(struct.pack('<I', 48000))
    header.extend(struct.pack('<I', 48000 * 2 * 2))
    header.extend(struct.pack('<H', 4))
    header.extend(struct.pack('<H', 16))
    header.extend(b'data')
    header.extend(struct.pack('<I', 0xFFFFFFFF))
    return header

# Sink that captures Discord voice audio and sends it to HTTP stream clients
class DiscordAudioSink(voice_recv.AudioSink):
    def __init__(self):
        super().__init__()
        self.last_packet_time = time.time()
        self.running = True
        self.silence_task = asyncio.create_task(self._inject_silence())

    async def _inject_silence(self):
        silence_frame = b'\x00' * 960
        while self.running:
            if time.time() - self.last_packet_time > 0.02:
                for client in list(stream_clients):
                    try:
                        await client.write(silence_frame)
                    except:
                        pass
            await asyncio.sleep(0.01)

    def wants_opus(self):
        return False

    def write(self, user, data):
        self.last_packet_time = time.time()
        for client in list(stream_clients):
            try:
                asyncio.run_coroutine_threadsafe(client.write(data.pcm), bot.loop)
            except:
                pass

    def cleanup(self):
        self.running = False
        self.silence_task.cancel()

@bot.event
async def on_ready():
    print(f'Discord bot online! Stream URL: http://localhost:{DISCORD_STREAM_PORT}/stream')

@bot.command()
async def join(ctx):
    if ctx.author.voice:
        channel = ctx.author.voice.channel
        if ctx.voice_client is not None:
            await ctx.voice_client.move_to(channel)
        else:
            vc = await channel.connect(cls=voice_recv.VoiceRecvClient)
            vc.listen(DiscordAudioSink())

        # Play TS3 audio in Discord (if ts3-listener is running)
        vc = ctx.voice_client
        if vc and not vc.is_playing():
            try:
                source = discord.FFmpegPCMAudio(
                    TS3_STREAM_URL,
                    before_options='-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5',
                    options='-ar 48000 -ac 2 -f wav'
                )
                vc.play(source)
                await ctx.send(f"Conectado! Bridge bidirecional ativo \ud83d\udd0a\u2194\ufe0f")
            except Exception as e:
                await ctx.send(f"Conectado! Discord\u2192TS3 ativo. TS3\u2192Discord falhou: {e}")
        else:
            await ctx.send(f"Conectado! Use `!play http://localhost:{DISCORD_STREAM_PORT}/stream` no TeamSpeak \ud83d\udd0a")
    else:
        await ctx.send("Entre em um canal de voz!")

@bot.command()
async def leave(ctx):
    if ctx.voice_client:
        await ctx.voice_client.disconnect()
        await ctx.send("Desconectado!")
    else:
        await ctx.send("N\u00e3o estou em nenhum canal!")

async def stream_handler(request):
    response = web.StreamResponse(
        status=200,
        headers={
            'Content-Type': 'audio/wav',
            'Connection': 'keep-alive',
            'Cache-Control': 'no-cache',
            'X-Accel-Buffering': 'no'
        }
    )
    await response.prepare(request)
    await response.write(get_wav_header())

    stream_clients.append(response)
    print("TS3AudioBot connected to WAV stream!")
    try:
        while True:
            await asyncio.sleep(3600)
    except:
        pass
    finally:
        if response in stream_clients:
            stream_clients.remove(response)
        return response

async def main():
    app = web.Application()
    app.router.add_get('/stream', stream_handler)
    # Increase client max size for safety
    runner = web.AppRunner(app, client_max_size=1024**2)
    await runner.setup()
    await web.TCPSite(runner, '0.0.0.0', DISCORD_STREAM_PORT).start()
    async with bot:
        await bot.start(TOKEN)

if __name__ == "__main__":
    asyncio.run(main())
