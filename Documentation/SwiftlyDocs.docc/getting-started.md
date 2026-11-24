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

## Windows: the Microsoft C runtime and the Windows SDK

On Windows, swiftly installs each toolchain from the swift.org installer into its own directory under `%LOCALAPPDATA%\swiftly\toolchains`, without running the installer, so several versions can be installed side by side and no administrator rights are needed.
`swiftly init` adds `%LOCALAPPDATA%\swiftly\bin` to your user `Path` (unless you pass `--no-modify-profile`); open a new terminal afterwards.

To link programs, Swift needs the Microsoft C runtime (MSVC) and the Windows SDK.
If Visual Studio or its Build Tools are installed with the C++ tools and a Windows SDK, the toolchains use them and swiftly downloads nothing from Microsoft.
Otherwise swiftly offers to download just the headers and libraries that Swift needs, directly from Microsoft, into `%LOCALAPPDATA%\swiftly\msvc-sysroot-<arch>`, which all toolchains share.
These are Microsoft software under Microsoft's license terms, which swiftly shows you before downloading; using the MSVC libraries requires a Visual Studio license (Visual Studio Community's terms cover individuals, open source projects and small organizations).
swiftly asks you to accept them; `--assume-yes` does not accept them for you.
To accept them non-interactively, for example in CI, set `SWIFTLY_ACCEPT_MSVC_LICENSE=1`:

```
PS> $env:SWIFTLY_ACCEPT_MSVC_LICENSE = 1
PS> swiftly init --assume-yes
```

`SWIFTLY_MSVC` changes where the Microsoft files come from: `auto` (the default) uses Visual Studio when it's installed and swiftly's download otherwise, `portable` always uses swiftly's download, and `system` never downloads anything from Microsoft.

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

