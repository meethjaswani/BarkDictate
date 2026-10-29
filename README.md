# BarkDictate

Hold Control + Option, talk, and your words show up in whatever app you're typing in. Everything runs on your Mac. No account, no internet, no audio leaving the machine.

![BarkDictate typing live while the notch island listens](docs/demo.gif)

## Why I made this

I was exploring open source models on Hugging Face and came across Bark 3.0 Pro, a speech model from Conway Research. By its makers' scoring it beats every other open model on the Open ASR Leaderboard's English tests, and the whole thing fits in about a gigabyte. I'd been using the Mac's built-in dictation for a while and kept getting annoyed at it, so I wanted to see what this model could do on a laptop.

It turned out to be fast. On my M4 MacBook Air it turns a few seconds of speech into text in about a tenth of a second. That made the obvious next step possible: type the words as I say them, and fix them as the model hears more. Then I wanted it to look good while it listens, so I gave it a little Dynamic Island in the notch.

This is the result. It's small and it does one job well. If you have an Apple Silicon Mac, you can set it up in about ten minutes with the steps below.

## What it does

- **Hold Control + Option** to talk. Let go and it finishes.
- **Tap Control + Option** once for hands-free mode. Tap again to stop.
- **Words appear while you speak** and get corrected as the model hears more, the way voice input works in chat apps.
- **Press Return** to stop. Your last words get typed first, then Return is pressed for you, so a message never sends half finished.
- **Stops by itself** after 30 seconds of silence.
- **Ignores background noise** instead of typing "yeah" into your document.
- **A notch island** with a pulsing dot and a live waveform shows when it's listening. On screens without a notch it becomes a small floating pill.

| Listening | Done |
|---|---|
| ![Island while listening](docs/island-listening.png) | ![Island when finished](docs/island-done.png) |

The images above are drawn from the app's own SwiftUI views using `--render-demo`.

## What you need

- A Mac with Apple Silicon (M1 or newer)
- macOS 15 Sequoia or newer
- About 3 GB of free space
- Apple's Command Line Tools (the setup script installs them if they're missing)

## Setup, step by step

**1. Open Terminal.** Press ⌘ Space, type `Terminal` and press Return.

**2. Download this project.** Paste this and press Return:

```bash
git clone https://github.com/meethjaswani/BarkDictate.git ~/BarkDictate
```

Keep it at `~/BarkDictate`. The app looks for the model there.

**3. Run the setup script.**

```bash
cd ~/BarkDictate
./setup.sh
```

This checks your Mac, downloads the model from Hugging Face (about 1.1 GB), builds the app and puts it in `~/Applications`. The first build takes a few minutes. If it asks you to install the Command Line Tools, click Install, wait for it to finish, then run `./setup.sh` again.

**4. Allow the microphone.** A popup will ask if BarkDictate can use the microphone. Click OK.

**5. Turn on Accessibility.** BarkDictate needs this to notice the Control + Option shortcut and to type for you. Open System Settings → Privacy & Security → Accessibility and switch on BarkDictate. If it isn't in the list, click **+** and pick it from your `Applications` folder inside your home folder.

**6. Try it.** Look for the microphone icon in your menu bar. The first launch spends about 30 seconds preparing the model, and later launches take a couple of seconds. Click into any text box, hold Control + Option and say something.

**7. Optional: start it when you log in.** System Settings → General → Login Items → click **+** and add BarkDictate.

## Using it

| Action | What happens |
|---|---|
| Hold ⌃⌥, talk, let go | Types as you speak, finishes when you let go |
| Tap ⌃⌥ | Hands-free: keeps listening until you tap again |
| Return while dictating | Types your last words, then presses Return |
| ⌃⌥ plus another key | Cancels, so your other ⌃⌥ shortcuts still work |
| 30 seconds of quiet | Stops on its own |

Click the menu bar icon to switch off **Type while I speak** if you'd prefer the text pasted in one go at the end.

## If something's off

**The island shows but nothing gets typed.** Accessibility is off for the current build. Each rebuild changes the app's signature and macOS forgets the old approval. Run `tccutil reset Accessibility com.meeth.barkdictate`, reopen the app and switch it on again in System Settings. When Accessibility is off, BarkDictate copies the text to your clipboard so nothing is lost.

**It types random words when the TV is on.** It filters out steady background noise, but voices from a TV still sound like speech. Press Return or tap ⌃⌥ to stop.

**No punctuation on short phrases.** The model adds punctuation and capitals on longer, natural sentences and often skips them on short ones. BarkDictate capitalises the start of each sentence and "I".

**The build fails with `'cmath' file not found`.** Your Command Line Tools have a leftover folder of old C++ headers. Move `/Library/Developer/CommandLineTools/usr/include/c++` somewhere else (it needs your admin password) and build again.

**Checking what it heard.** Every dictation is written to `~/BarkDictate/bark.log`. That file stays on your Mac and is excluded from git.

## How it works

- **Model:** [Underdog Bark 3.0 Pro](https://huggingface.co/ConwayResearch/Underdog-Bark-3.0-Pro), the Core ML version, running on the Apple Neural Engine through [FluidAudio](https://github.com/FluidInference/FluidAudio).
- **Live typing:** while you talk, the current stretch of audio is transcribed again every 0.35 seconds. The newest guess is typed straight away and corrected with backspaces when it changes. At each pause that stretch is finalised and a new one starts, so every pass stays short.
- **Noise:** a simple loudness check tracks the background level of your room. Audio that never rises clearly above it isn't sent to the model.
- **Notch island:** [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) by Kai Azim, included in `app/Vendor` with two small changes so it builds without full Xcode.

## For developers

```bash
./build.sh                                              # rebuild and reinstall
app/.build/release/BarkDictate --file clip.wav          # transcribe a mono 16 kHz WAV
app/.build/release/BarkDictate --simulate clip.wav      # stream a WAV through live typing, print what would be typed
app/.build/release/BarkDictate --render-demo docs       # redraw the README images
```

All the app code lives in `app/Sources/BarkDictate/main.swift`.

## Credits

- **Underdog Bark 3.0 Pro** by Conway Research, built on [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) and [moondream/parakeet-ultra](https://huggingface.co/moondream/parakeet-ultra). Licensed CC BY 4.0. The model isn't stored in this repo. `download-model.sh` fetches it from Hugging Face.
- **FluidAudio** by FluidInference, Apache 2.0.
- **DynamicNotchKit** by Kai Azim, MIT. See `app/Vendor/DynamicNotchKit/LICENSE`.

## License

The BarkDictate code is MIT licensed. See [LICENSE](LICENSE).
