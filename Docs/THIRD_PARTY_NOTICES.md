# Third-Party Notices

This project includes planning for third-party and upstream open-source acknowledgements.

## Project License

- Project: `Atlas for Mac`
- License: `MIT`

## Upstream Project

- Project: `Mole`
- Source: `https://github.com/tw93/mole`
- License: `MIT`
- Copyright: `tw93`

## Distribution Rule

If Atlas for Mac ships code derived from upstream Mole sources, the applicable copyright notice and MIT license text must be included in copies or substantial portions of the software.

## Notice Template

```text
Atlas for Mac is released under the MIT License. This product also includes software derived from the open-source project Mole (https://github.com/tw93/mole) by tw93 and contributors, used under the MIT License.
```

## Future Additions

Add all additional third-party libraries, bundled binaries, or copied source components here before release.

## Atlas safety changes (2026-10-01)

Mole-derived Shell components are modified to disable automatic PAM changes, privileged deletion, system update/service removal, network/Bluetooth resets and Trash emptying. Ordinary cache deletion requires Atlas's confined backend. Original MIT attribution remains applicable.

### Atlas hardening additions (2026-10-04)

Atlas's PAM transaction, confined Go cache backend, file-object validation, journal and bounded process lifecycle do not add third-party dependencies. Mole-derived Shell safety behavior and synchronized runtime copies differ from upstream; original MIT notices are retained. Existing Go dependencies and their notices continue to apply.
