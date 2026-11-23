# nvr

Frigate as the cluster's NVR: records cameras, detects objects, serves the
UI and the RTSP/WebRTC restream (go2rtc built in).

- **Configuration:** `frigate_config` is the content of Frigate's
  `config.yml` as an object (cameras, go2rtc streams, detectors, record,
  objects). It is rendered to a ConfigMap and copied onto `/config` by an
  init container on every start, so the declared configuration always wins.
  The module sets `database.path` and, unless given, `mqtt.enabled: false`.
- **Credentials:** every key at `vault_path` (KV v2, mount `secret`) becomes
  an environment variable through VSO. Use `FRIGATE_*` names and refer to
  them as `{FRIGATE_...}` in the configuration. A change restarts Frigate.
- **Storage:** `/config` (database, model cache) and `/media/frigate`
  (recordings, clips, exports) on two ReadWriteOnce PVCs of
  `storage_class`; `/dev/shm` and `/tmp/cache` are memory-backed.
- **Access:** Service `frigate`, port 5000 is Frigate's UI/API **without its
  own login** — route it only through an authenticating gate (for example
  `auth: zitadel` on a `kind: external` component). 8554 is the RTSP
  restream, 8555 WebRTC (two-way talk).
- **Monitoring:** ServiceMonitor on `/api/metrics`; alerts `FrigateDown`
  and `FrigateRecordingsVolumeFull`.

```hcl
module "nvr" {
  source          = "./modules/nvr"
  context         = module.platform_label.context
  enabled         = true
  storage_class   = "replicated-class"
  recordings_size = "1Ti"
  node_selector   = { "node-pool" = "storage" }
  frigate_config = {
    go2rtc  = { streams = { door = ["rtsp://{FRIGATE_DOOR_USER}:{FRIGATE_DOOR_PASSWORD}@camera:554/ch0"] } }
    cameras = { door = { ffmpeg = { inputs = [{ path = "rtsp://127.0.0.1:8554/door", input_args = "preset-rtsp-restream", roles = ["record", "detect"] }] } } }
  }
}
```

Frigate runs as root inside its image (s6 supervisor), so the namespace is
Pod Security `baseline`, not `restricted`.
