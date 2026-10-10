# Building and running ScreenTake

- For requests to build or run the current app, use `./Launch ScreenTake.command` from the project root.
- The required signing identity is `Developer ID Application: So Eun Ahn (43LSH32H5S)`, with `CODE_SIGNING_ALLOWED=YES` and `CODE_SIGNING_REQUIRED=YES`.
- Do not disable signing, use ad hoc signing, or substitute `Screen Local Development` to work around a signing failure unless the user explicitly requests that change.
- Restricted execution can hide keychain identities and block macOS app launching. If identity lookup or launching fails under the sandbox, retry the signed launch script with the required execution permissions before concluding the certificate is missing.
- Verify the resulting app's signing identity and that the current build is running before reporting success. Do not claim a certificate or private key is absent based only on a sandboxed identity lookup.
