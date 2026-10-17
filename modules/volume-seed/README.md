# volume-seed

Shared convention for modules that move their data from a hostPath directory
(or an older volume) into a StorageClass volume: the app's data lives in the
volume's `data/` directory (mounted with subPath `data`), and a one-time init
container copies the old data in on the first start. See `main.tf` for the
layout and the rules (copies only into an empty `data/`, once).

Used by `component`, `mysql`, `stalwart`, `roundcube`, `seafile` through their
`storage_class` and `storage_seed_*` variables.
