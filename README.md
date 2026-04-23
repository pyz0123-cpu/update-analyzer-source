# Update Analyzer — Source Code

This repository contains the full source code for **Update Analyzer**, a small personal tool for inspecting available system updates. The binary release generated interest, so the source is published here for transparency and auditing.

## Purpose
Update Analyzer provides a minimal UI that surfaces update metadata normally hidden or scattered across multiple tools. It is not a package manager.

## License
This project is released under the MIT License. See the `LICENSE` file for details.

## Building
To build the Linux release:

1. Install Flutter (stable channel).
2. Clone this repository.
3. Run:
   flutter pub get
4. Build:
   flutter build linux --release
5. The compiled binary will appear in:
   build/linux/x64/release/bundle/

## Support
This is a personal project.  
Issues, pull requests, and feature requests are not enabled.  However, forking and modifying the code is fully allowed under the MIT License. You are welcome to adapt it for your own use.
