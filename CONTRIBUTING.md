# Contributing to Nativerate

Thanks for helping. The most useful contributions right now are reports from hardware we haven't
tested.

## Reporting a bug

Open an issue with the **Bug report** template. Include your DAC, macOS version, and the output of
**Bit-perfect check**, and attach the zip from **About Nativerate > Export logs…**. Without the logs, most
playback problems can't be told apart.

## Reporting hardware

If Nativerate works (or doesn't) with your DAC, the **Hardware report** template takes a minute and
helps everyone with the same device.

## Code

Build instructions are in the [README](README.md#build-it); the virtual output device is in
[`HALPlugin/`](HALPlugin/README.md).

- Open an issue before starting anything large, so we can agree on the approach.
- Keep pull requests to one change, and say in the description how you tested it and on what
  hardware.
- Audio-path changes need a note on whether the output is still bit-perfect, and how you checked.
- Before a pull request is opened, run an adversarial check on it (try to break it: edge cases, regressions, audio path, accessibility). Mace Windu always does this for agent-written changes; the PR description says what was checked and what was found.

By contributing you agree that your work is licensed under the [GPL-3.0](LICENSE).
