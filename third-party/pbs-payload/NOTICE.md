# PBS Payload

PBS (PlayStation Broadcast Stream) is a separate program by seregonwar and contributors:
<https://github.com/seregonwar/PBS-Payload>. It is licensed under the GNU General Public License v3.0; the
license text is in `LICENSE` next to this file.

PS5 MCP does not include, modify, or redistribute PBS. On request, `ps5mcp get-pbs` (or Load PBS in the app's
Settings) downloads one pinned upstream release directly from GitHub, checks its SHA256, and adds it to Payload
Manager's library on the console. PS5 MCP and PBS communicate only over HTTP.

| Field | Value |
| --- | --- |
| Release | `v0.4.0-beta.6` (pre-release, 2026-11-11) |
| Source commit | `c5ed4840d96f9679eecdb560d7d57ebec6e233a9` |
| File | `PBS-Payload-0.4.0-beta.6-ps5.elf` |
| SHA256 | `5f7bde34491b80f31b08095790e20f405de82b4646aa4349a69cfc59d5e4772f` |
| Download | <https://github.com/seregonwar/PBS-Payload/releases/download/v0.4.0-beta.6/PBS-Payload-0.4.0-beta.6-ps5.elf> |
| Corresponding source | <https://github.com/seregonwar/PBS-Payload/tree/v0.4.0-beta.6> |

To change the pinned release, update `VERSION` and `SHA256` in `src/ps5mcp/pbs.py` and this table together.
