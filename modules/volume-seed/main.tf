# Shared by the modules that can move their data from a hostPath directory (or
# an older volume) into a StorageClass volume. Layout inside every such volume:
#
#   data/        the app's data; the app mounts the volume with subPath "data"
#   .seeded      marker: the one-time copy has run
#   .seed-tmp    only while copying
#   lost+found   (ext4) kept out of the app's view (MySQL refuses to initialise
#                a data directory that is not empty)
#
# The copy runs in an init container with the new volume at /new and the old
# data read-only at /old. It copies only into an empty data/ and only once, so
# the app never starts on an empty (or half-copied) volume and existing data
# is never overwritten.
#
# Callers keep their old PV/PVC objects while seeding: Kubernetes does not
# delete a claim a pod still uses, and Terraform deletes it before it updates
# the workload, so dropping it in the same apply stalls until a timeout. The
# old objects go when the seed setting is cleared and nothing uses them.

output "sub_path" {
  description = "subPath the app mounts its volume with."
  value       = "data"
}

output "script" {
  description = "sh script for the seeding init container (busybox)."
  # The copy goes to .seed-tmp and becomes data/ by a rename at the end, so
  # an interrupted copy (OOM, node loss) is never taken for a finished one: a
  # leftover .seed-tmp is removed and the copy starts over. A non-empty data/
  # without the marker is data that was there before seeding: kept as is.
  value = <<-EOT
    set -e
    if [ -e /new/.seeded ]; then echo "seed: done before"; exit 0; fi
    if [ -n "$(ls -A /new/data 2>/dev/null)" ]; then
      echo "seed: data/ already holds data, nothing copied"
    else
      rm -rf /new/.seed-tmp
      mkdir /new/.seed-tmp
      echo "seed: copying the old data"
      cp -a /old/. /new/.seed-tmp/
      sync
      rm -rf /new/data
      mv /new/.seed-tmp /new/data
    fi
    touch /new/.seeded
    sync
    echo "seed: done"
  EOT
}

output "resources" {
  description = "Resources for the seeding init container: the copy goes through the page cache, which counts against the container's memory limit (64Mi was OOM-killed copying 110 MB onto a DRBD volume)."
  value = {
    requests = { cpu = "10m", memory = "64Mi" }
    limits   = { cpu = "1", memory = "1Gi" }
  }
}
