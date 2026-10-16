# Third-party notices

CodexPocket includes the following third-party software. Their licenses remain
separate from the project's MIT license. Redistributed connector executables
must include this notice and the `licenses/` directory, including Node's complete
third-party notices.

| Component | Version | License text |
| --- | --- | --- |
| Node.js runtime | 24.19.0 | [Node license and bundled notices](licenses/node/LICENSE) |
| ws | 8.21.3 | [MIT](licenses/ws/LICENSE) |
| qrcode-generator | 1.4.4 | [MIT](licenses/qrcode-generator/LICENSE) |
| postject (build tool) | 1.0.0-alpha.6 | [MIT](licenses/postject/LICENSE) |
| commander (build dependency) | 9.5.0 | [MIT](licenses/commander/LICENSE) |
| Lucide static icons | 1.56.0 | [ISC and Feather MIT](licenses/lucide/LICENSE) |
| Mermaid | 10.9.1 | [MIT](licenses/mermaid/LICENSE) |
| DOMPurify (in Mermaid) | 3.0.9 | [Apache 2.0 or MPL 2.0](licenses/dompurify/LICENSE) |

Lucide's icon provenance is recorded in [its manifest](licenses/lucide/manifest.json).
QR Code is a registered trademark of DENSO WAVE INCORPORATED; the QR generator's
upstream source retains its trademark notice.

## Mermaid bundle dependencies

`CodexPocket/Resources/mermaid.min.js` matches the distributed JavaScript in
the official `mermaid@10.9.1` npm archive byte for byte. The dependency versions
are taken from the [upstream release lockfile](https://github.com/mermaid-js/mermaid/blob/v10.9.1/pnpm-lock.yaml).

The [dependency manifest](licenses/mermaid-dependencies/manifest.json) records
the 106 packages in that release's declared runtime dependency graph, their
versions, npm archive sources, upstream integrity hashes and license files.
The graph also includes type definitions; preserving their notices does not
imply that they execute inside the app. Archive integrity was checked against
the upstream lockfile before extracting notices.

Some micromark archives publish only a README license link. Their complete
upstream MIT license is included alongside those READMEs. The Dagre ES package
also omits a standalone license; its MIT declaration and incorporated Dagre,
Dagre-D3 and Graphlib notices are documented in
[the package notice](licenses/mermaid-dependencies/dagre-d3-es@7.0.10/NOTICE).
