# Third-party notices

Rosa Thermal Guard's own code is MIT-licensed (see `LICENSE`). The installer bundles
the following unmodified third-party binaries in `lib\`:

| Component | License | Source |
|---|---|---|
| LibreHardwareMonitorLib (v0.9.6) | Mozilla Public License 2.0 (`licenses/LibreHardwareMonitor-MPL-2.0.txt`) | https://github.com/LibreHardwareMonitor/LibreHardwareMonitor |
| HidSharp | Apache License 2.0 | https://www.zer7.com/software/hidsharp |
| BlackSharp.Core, DiskInfoToolkit, RAMSPDToolkit-NDD | see upstream (shipped with the LibreHardwareMonitor release) | https://github.com/LibreHardwareMonitor |
| System.* / Microsoft.Bcl.* (.NET packages) | MIT | https://github.com/dotnet/runtime |

The source code of LibreHardwareMonitorLib is available at the link above, as required by MPL-2.0.

Not bundled: the **PawnIO** driver (needed for CPU temperatures) is installed separately from https://pawnio.eu.

Installer translations (`installer/languages/*.isl`) come from the Inno Setup project
(https://github.com/jrsoftware/issrc) and keep their translators' credits.
