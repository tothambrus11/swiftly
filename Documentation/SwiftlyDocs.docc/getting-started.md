# Getting started with swiftly

Start using swiftly and Swift.

To get started with swiftly you can download it from [swift.org](https://swift.org/download), and extract the package.

@TabNavigator {
    @Tab("Linux") {
        If you are using Linux then you can download the binary:

        ```
        curl -L https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz > swiftly.tar.gz
        tar zxf swiftly.tar.gz
        ```

        Now run swiftly init to finish the installation:

        ```
        ./swiftly init
        ```
    }

    @Tab("macOS") {
        On macOS you can either run the pkg installer from the command-line like this or run the package by double-clicking on it (not recommended):

        ```
        curl -L https://download.swift.org/swiftly/darwin/swiftly.pkg > swiftly.pkg
        installer -pkg swiftly.pkg -target CurrentUserHomeDirectory
        ```

        Once the package is installed, run `swiftly init` to finish the installation:

        ```
        ~/.swiftly/bin/swiftly init
        ```
    }
}

Swiftly installs itself and downloads the latest available Swift toolchain.
Follow the prompts for any additional steps that may be required.
Once everything is done you can begin using swift.

```
$ swift --version

Swift version 6.0.3 (swift-6.0.3-RELEASE)
...

$ swift build        # Build with the latest (6.0.3) toolchain
```

You can install (and use) another release toolchain:

```
$ swiftly install --use 5.10

$ swift --version

Swift version 5.10.1 (swift-5.10.1-RELEASE)
...

$ swift build    # Build with the 5.10.1 toolchain
```

Quickly test your package with the latest nightly snapshot to prepare for the next release:

```
$ swiftly install main-snapshot
$ swiftly run swift test +main-snapshot   # Run "swift test" with the main-snapshot toolchain
$ swift build                             # Continue to build with my usual toolchain
```

Uninstall this toolchain after you're finished with it:

```
$ swiftly uninstall main-snapshot
```

## Windows

On Windows, swiftly installs each toolchain from the swift.org installer into its own directory under `%LOCALAPPDATA%\swiftly\toolchains`, without running the installer, so several versions can be installed side by side and no administrator rights are needed.
`swiftly init` adds `%LOCALAPPDATA%\swiftly\bin` to your user `Path` (unless you pass `--no-modify-profile`); open a new terminal afterwards.

As with the swift.org installer, Swift needs Visual Studio or its Build Tools, with the C++ tools and a Windows SDK, to link programs.
If they're missing, swiftly still installs the toolchain and prints the command that installs them.

Without Visual Studio, `swiftly install --msvc=install-build-tools` runs Microsoft's installer for the Visual Studio Build Tools with the components Swift needs; Microsoft's installer shows Microsoft's license terms.

As a prototype, `swiftly install --msvc=portable` (or `init --msvc=portable`, which applies at the first toolchain install) can instead download just the headers and libraries of the Microsoft C runtime and the Windows SDK that Swift needs, directly from Microsoft, into `%LOCALAPPDATA%\swiftly\msvc-sysroot-<arch>`, which your toolchains then share.
These are Microsoft software under the Visual Studio Build Tools' and the Windows SDK's license terms, which swiftly shows (it fetches the license documents and Microsoft's package metadata first, and the packages only once you accept). Whether the terms cover your use is between you and Microsoft; see [Microsoft's description](https://visualstudio.microsoft.com/license-terms/).
swiftly asks you to accept them; `--assume-yes` doesn't accept them for you, `--accept-msvc-license` (or `SWIFTLY_ACCEPT_MSVC_LICENSE=1`) does, though not terms that changed since you accepted them: those need an answer at the prompt, or `SWIFTLY_ACCEPT_MSVC_LICENSE=<identifier>` with the identifier swiftly shows.
swiftly doesn't support sharing the sysroot: each user and machine accepts and downloads it (so it isn't for CI caches or a network `SWIFTLY_HOME_DIR`).
Each toolchain gets clang and clang-cl configuration files for this machine's target (both the `unknown` and the `pc` vendor), so building for other targets isn't affected.
To download it again, add `--msvc-refresh`. `--msvc=visual-studio` points the toolchains back at Visual Studio, and `--msvc-remove` deletes the sysroot and swiftly's configuration of the toolchains for it.
Its packages are checked against the hashes in Microsoft's metadata, which comes over HTTPS; their signatures aren't verified.
With the Visual Studio 2026 STL (14.50 and later), which expects clang 22, toolchains with an older clang (Swift 6.2 to 6.4) get `_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH` defined, with a warning.

Programs you build link against the Swift runtime DLLs of their toolchain. `swift run` and `swiftly run` put them on the `Path`; to start a program directly, run it with `swiftly run .\program.exe`.

## Installing toolchains through an HTTP proxy

Swiftly downloads a list of toolchains from https://www.swift.org/ and retrieves them from CDN via https://download.swift.org.
If your environment requires a proxy, Swiftly attempts to use the standard environment variables `http_proxy`, `HTTP_PROXY`, `https_proxy` or `HTTPS_PROXY` to determine which proxy server to use instead of making a direct connection.

To download latest nightly snapshot using a proxy:
```
$ export https_proxy=http://proxy:3128
$ swiftly install main-snapshot
```

## See Also:

- <doc:shell-autocompletion>
- <doc:install-toolchains>
- <doc:use-toolchains>
- <doc:uninstall-toolchains>
- <doc:swiftly-cli-reference>

