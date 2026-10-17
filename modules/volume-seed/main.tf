# Shared by the modules that can move their data from a hostPath directory (or
# an older volume) into a StorageClass volume. Layout inside every such volume:
#
#   data/        the app's data; the app mounts the volume with subPath "data"
#   .seeded      marker: the one-time copy has run
#   lost+found   (ext4) kept out of the app's view (MySQL refuses to initialise
#                a data directory that is not empty)
#
# The copy runs in an init container with the new volume at /new and the old
# data read-only at /old. It copies only into an empty data/ and only once, so
# the app never starts on an empty volume and existing data is never
# overwritten.

output "sub_path" {
  description = "subPath the app mounts its volume with."
  value       = "data"
}

output "script" {
  description = "sh script for the seeding init container (busybox)."
  value       = <<-EOT
    set -e
    if [ -e /new/.seeded ]; then echo "seed: done before"; exit 0; fi
    mkdir -p /new/data
    if [ -n "$(ls -A /new/data)" ]; then
      echo "seed: data/ is not empty, nothing copied"
    else
      echo "seed: copying the old data"
      cp -a /old/. /new/data/
    fi
    touch /new/.seeded
    echo "seed: done"
  EOT
}
