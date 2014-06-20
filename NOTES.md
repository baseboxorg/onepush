`onepush setup`:

 * The server is the primary source of truth, not the config file. Prefer autodetecting state from the server instead of reading state from the config file.
 * Try not to completely alter the status quo of the server, but to use it.

`onepush deploy`:

 * `onepush deploy` can consider `onepush-setup.json` on the server as the primary source of truth.