#!/bin/bash -eu

function log_progress () {
  if declare -F setup_progress > /dev/null
  then
    setup_progress "create-backingfiles: $1"
    return
  fi
  echo "create-backingfiles: $1"
}

function calc_size () {
  local requestedsize="${1:?}"
  local mountpoint="${2:?}"
  local availablesize
  availablesize="$(available_space "$mountpoint")"
  if [ "$availablesize" -lt 0 ]
  then
    echo "0"
    return
  fi
  if is_percent "$requestedsize"
  then
    local percent=${requestedsize//%/}
    requestedsize="$(( availablesize * percent / 100 ))"
  else
    requestedsize="$(( $(dehumanize $requestedsize) / 1024 ))"
  fi
  if [ "$requestedsize" -gt "$availablesize" ]
  then
    requestedsize="$availablesize"
  fi
  echo "$requestedsize"
}

function is_percent() {
  echo "$1" | grep '%' > /dev/null
}

function dehumanize () {
  # Note that this uses powers-of-two rather than the powers-of-ten that are
  # generally used to market storage.
  local value="${1:?}"
  if echo "$value" | grep -E '[0-9]+[GMK]B?' > /dev/null
  then
    echo $(($(echo "$value" | sed 's/GB/G/;s/MB/M/;s/KB/K/;s/G/*1024M/;s/M/*1024K/;s/K/*1024/')))
  else
    echo "ERROR: value $value not supported"
    exit 1
  fi
}

function first_partition_offset () {
  local filename="$1"
  local size_in_bytes
  local size_in_sectors
  local sector_size
  local partition_start_sector

  size_in_bytes=$(sfdisk -l -o Size -q --bytes "$1" | tail -1)
  size_in_sectors=$(sfdisk -l -o Sectors -q "$1" | tail -1)
  sector_size=$(( size_in_bytes / size_in_sectors ))
  partition_start_sector=$(sfdisk -l -o Start -q "$1" | tail -1)

  echo $(( partition_start_sector * sector_size ))
}

function available_space () {
  local mountpoint="${1:?}"
  local freespace=""
  local padding=""

  freespace=$(df --output=avail --block-size=1K "$mountpoint/" | tail -n 1)
  # leave 10 GB of free space for filesystem bookkeeping and snapshotting
  # (in kilobytes so 10M KB)
  padding=$(dehumanize "10M")
  echo $((freespace-padding))
}

function add_drive () {
  local name="$1"
  local label="$2"
  local size="$3"
  local filename="$4"
  local useexfat="$5"
  
  if [ -e "$filename" ]
  then
    log_progress "Backing file $filename already exists, nothing to do. To resize it, remove it and rerun setup-teslausb"
    return
  fi
  log_progress "Allocating ${size}K for $filename..."
  fallocate -l "$size"K "$filename"
  if [ "$useexfat" = true  ]
  then
    echo "type=7" | sfdisk "$filename" > /dev/null
  else
    echo "type=c" | sfdisk "$filename" > /dev/null
  fi

  local partition_offset
  partition_offset=$(first_partition_offset "$filename")

  loopdev=$(losetup -o "$partition_offset" -f --show "$filename")
  log_progress "Creating filesystem with label '$label'"
  if [ "$useexfat" = true  ]
  then
    mkfs.exfat "$loopdev" -L "$label"
  else
    mkfs.vfat "$loopdev" -F 32 -n "$label"
  fi
  losetup -d "$loopdev"

  local mountpoint=/mnt/"$name"

  if [ ! -e "$mountpoint" ]
  then
    mkdir "$mountpoint"
  fi
}

function check_for_exfat_support () {
  # First check for built-in ExFAT support
  # If that fails, check for an ExFAT module
  # in this last case exfat doesn't appear
  # in /proc/filesystems if the module is not loaded.
  if grep -q exfat /proc/filesystems &> /dev/null
  then
    return 0;
  elif modprobe -n exfat &> /dev/null
  then
    return 0;
  else 
    return 1;  
  fi
}

function main () {
  log_progress "starting"

  local CAM_SIZE="$1"
  local MUSIC_SIZE="$2"
  local BOOMBOX_SIZE="$3"
  # strip trailing slash that shell autocomplete might have added
  local BACKINGFILES_MOUNTPOINT="${4/%\//}"
  local USE_EXFAT="$5"

  local CAM_DISK_FILE_NAME="$BACKINGFILES_MOUNTPOINT/cam_disk.bin"
  local MUSIC_DISK_FILE_NAME="$BACKINGFILES_MOUNTPOINT/music_disk.bin"
  local BOOMBOX_DISK_FILE_NAME="$BACKINGFILES_MOUNTPOINT/boombox_disk.bin"

  log_progress "cam: $CAM_SIZE, music: $MUSIC_SIZE, boombox: $BOOMBOX_SIZE mountpoint: $BACKINGFILES_MOUNTPOINT, exfat: $USE_EXFAT"

  # delete existing files, because fallocate doesn't shrink files, and
  # because they interfere with the percentage-of-free-space calculation
  if [ -e "$CAM_DISK_FILE_NAME" ] || [ -e "$MUSIC_DISK_FILE_NAME" ] || [ -e "$BOOMBOX_DISK_FILE_NAME" ] || [ -e "$BACKINGFILES_MOUNTPOINT/snapshots" ]
  then
    # when executed interactively, ask the user what to do
    if [ -t 0 ]
    then
      read -r -p 'Delete snapshots and recreate recording and music drives? (yes/cancel)' answer
      case ${answer:0:1} in
        y|Y )
          log_progress "stopping all services"
          killall archiveloop || true
          /root/bin/disable_gadget.sh || true
          umount -d /mnt/cam || true
          umount -d /mnt/music || true
          umount -d /mnt/boombox || true
          umount -d /backingfiles/snapshots/snap*/mnt || true
          log_progress "deleting backing files at $BACKINGFILES_MOUNTPOINT"
          rm -f "$CAM_DISK_FILE_NAME"
          rm -f "$MUSIC_DISK_FILE_NAME"
          rm -f "$BOOMBOX_DISK_FILE_NAME"
          rm -rf "$BACKINGFILES_MOUNTPOINT/snapshots"
        ;;
        * )
          log_progress "INFO: Deletion aborted"
          exit
        ;;
      esac
    else
      log_progress "WARNING: $BACKINGFILES_MOUNTPOINT already contains backing files. In case you want to resize them, delete the affected files and rerun setup-teslausb"
    fi
  fi

  # Check if kernel supports ExFAT 
  if ! check_for_exfat_support
  then
    if [ "$USE_EXFAT" = true ]
    then
      log_progress "INFO: kernel does not support ExFAT FS. Reverting to FAT32."
      USE_EXFAT=false
    fi
  else
    # install exfatprogs if needed
    if ! hash mkfs.exfat &> /dev/null
    then
      /root/bin/remountfs_rw
      if ! apt install -y exfatprogs
      then
        log_progress "WARNING: kernel supports ExFAT, but exfatprogs package could not be installed"
        if [ "$USE_EXFAT" = true ]
        then
          log_progress "WARNING: Reverting to FAT32"
          USE_EXFAT=false
        fi
      fi
    fi
  fi

  # some distros don't include mkfs.vfat
  if ! hash mkfs.vfat
  then
    apt-get -y --force-yes install dosfstools
  fi

  CAM_DISK_SIZE="$(calc_size "$CAM_SIZE" "$BACKINGFILES_MOUNTPOINT")"
  MUSIC_DISK_SIZE="$(calc_size "$MUSIC_SIZE" "$BACKINGFILES_MOUNTPOINT")"
  BOOMBOX_DISK_SIZE="$(calc_size "$BOOMBOX_SIZE" "$BACKINGFILES_MOUNTPOINT")"

  add_drive "cam" "CAM" "$CAM_DISK_SIZE" "$CAM_DISK_FILE_NAME" "$USE_EXFAT"
  log_progress "INFO: created camera backing file"

  REMAINING_SPACE="$(available_space "$BACKINGFILES_MOUNTPOINT")"

  if [ "$CAM_SIZE" = "100%" ]
  then
    MUSIC_DISK_SIZE=0
  elif [ "$MUSIC_DISK_SIZE" -gt "$REMAINING_SPACE" ]
  then
    MUSIC_DISK_SIZE="$REMAINING_SPACE"
  fi

  if [ "$REMAINING_SPACE" -ge 1024 ] && [ "$MUSIC_DISK_SIZE" -gt 0 ]
  then
    add_drive "music" "MUSIC" "$MUSIC_DISK_SIZE" "$MUSIC_DISK_FILE_NAME" "$USE_EXFAT"
    log_progress "created music backing file: $MUSIC_DISK_FILE_NAME"
  fi

  REMAINING_SPACE="$(available_space "$BACKINGFILES_MOUNTPOINT")"
  if [ "$BOOMBOX_DISK_SIZE" -gt "$REMAINING_SPACE" ]
  then
    BOOMBOX_DISK_SIZE="$REMAINING_SPACE"
  fi

  if [ "$REMAINING_SPACE" -ge 1024 ] && [ "$BOOMBOX_DISK_SIZE" -gt 0 ]
  then
    add_drive "boombox" "BOOMBOX" "$BOOMBOX_DISK_SIZE" "$BOOMBOX_DISK_FILE_NAME" "$USE_EXFAT"
    log_progress "INFO: created boombox backing file: $BOOMBOX_DISK_FILE_NAME"
  fi

  log_progress "INFO: done"

}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
    main "$@"
fi
