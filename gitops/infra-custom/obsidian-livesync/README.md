# Obsidian Self-hosted LiveSync

This application provides the cluster-side CouchDB endpoint used by the
[Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync) Obsidian
plugin. The plugin itself remains installed on each Obsidian client.

## Architecture

- Single-node CouchDB with the upstream LiveSync CORS and request-size settings.
- A 10 GiB Longhorn data volume and a 1 GiB persistent configuration volume.
- TLS ingress at `https://livesync.homelab.niekvlam.nl`.
- CouchDB admin credentials sourced from 1Password through External Secrets.
- Ingress restricted to the nginx ingress-controller namespace.

## Required 1Password values

Create an item named `obsidian-livesync` in the `Homelab` vault before the
Argo CD application is reconciled, with these fields:

- `username`
- `password`

Use a unique, randomly generated password. The resulting Kubernetes Secret is
named `obsidian-livesync-credentials`; credentials are never stored in Git.

## First client setup

1. Install and enable the Self-hosted LiveSync community plugin in Obsidian.
2. Configure CouchDB with:
   - URI: `https://livesync.homelab.niekvlam.nl`
   - Database: a lowercase name such as `obsidiannotes`
   - Username and password: the 1Password values above
3. Test the connection and let the plugin create/initialise the remote database.
4. Enable end-to-end encryption with a separate strong passphrase.
5. Verify normal note sync before enabling hidden-file or customisation sync.
6. Generate a fresh Setup URI from the working first device for each additional
   device, and store its passphrase separately.

Back up the vault before enabling any sync solution. Do not run Self-hosted
LiveSync alongside Obsidian Sync, iCloud Drive, or another filesystem sync tool.
