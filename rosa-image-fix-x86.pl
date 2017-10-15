#!/usr/bin/perl

use strict;
use warnings;

use Fcntl ':seek';
use String::CRC32;

if (scalar(@ARGV) < 1) {
	print "Usage: $0 iso-image-file\n";
	exit;
}

my $filename = $ARGV[0];
my $file;
open($file, '+<', $filename) or die "Failed to open file $filename for read-write: $!";
binmode($file);

################################################################################
# Fixing MBR

# Read the first sector (512 bytes) containing the MBR
my $mbr;
read($file, $mbr, 512) or die "Failed to read the MBR sector: $!";

# Extract the second partition record from the MBR (except for the "bootable" flag)
my $partition2 = substr($mbr, 463, 15);

# In 32-bit images we don't have the second partition (EFI), so here we'll create
# a fake partition without actual file system.
if ($partition2 eq ("\x00" x 15)) {
	# Partition recod
	$partition2 = "\x00\x02\x00" .     # CHS: first sector = 2
	              "\xDA" .             # partition type: non-filesystem data
	              "\x00\x02\x00" .     # CHS: last sector = 2
	              "\x01\x00\x00\x00" . # LBA: first sector = 1
	              "\x01\x00\x00\x00";  # LBA: number of sectors = 1
}

# Now write back the desired partition table into MBR.
# The partition table starts at offset 446 and contains 4 records 16 bytes each. What we do:
# 1) Replace the first record with the second one (real or faked for 32-bit images);
# 2) Replace the first byte of the resulting first record with 0x80 (mark partition as active);
# 3) Delete the second partition by zeroing its contents.
substr($mbr, 446, 32) = "\x80" . $partition2 . ("\x00" x 16);

# Write the updated MBR back
seek($file, 0, SEEK_SET) or die "Failed to position at the beginning of the file: $!";
print $file $mbr;

print "MBR table updated.\n";

################################################################################
# Fixing GPT

# Auxiliary functions to read/write binary values from/to string consisting of bytes
sub getUInt32($$) {
	# Arguments: source string, offset
	return unpack("L", substr($_[0], $_[1], 4));
}
sub getUInt64($$) {
	# Arguments: source string, offset
	return unpack("Q", substr($_[0], $_[1], 8));
}
sub putUInt32($$$) {
	# Arguments: source/destination string, offset, value
	substr($_[0], $_[1], 4) = pack("L", $_[2]);
}

# Reading the second sector containing the GPT header
my $gpt_header;
seek($file, 512, SEEK_SET) or die "Failed to position at the LBA 1: $!";
read($file, $gpt_header, 512) or die "Failed to read the GPT sector: $!";
if (substr($gpt_header, 0, 8) ne 'EFI PART') {
	print "No GPT table found, exiting.\n";
	close($file);
	exit(0);
}

# Get various data from the header
my $gpt_header_size =    getUInt32($gpt_header, 0x0c); # Size of the header in bytes (normally, 92)
my $gpt_backup_lba =     getUInt64($gpt_header, 0x20); # LBA address of the backup GPT header
my $gpt_partitions_lba = getUInt64($gpt_header, 0x48); # LBA address of the partitions array
my $gpt_partitions_num = getUInt32($gpt_header, 0x50); # Number of partition entries (usually, 128)
my $gpt_partition_size = getUInt32($gpt_header, 0x54); # Size of a single partition entry (usually, 128 bytes)

# Reading the list of partitions
my $gpt_part;
seek($file, $gpt_partitions_lba * 512, SEEK_SET) or die "Failed to position at the GPT partitions array (LBA $gpt_partitions_lba): $!";
read($file, $gpt_part, $gpt_partitions_num * $gpt_partition_size) or die "Failed to read the GPT partitions array: $!";

# Moving the second partition entry to replace first, and zeroing the second entry
substr($gpt_part, 0, $gpt_partition_size) = substr($gpt_part, $gpt_partition_size, $gpt_partition_size);
substr($gpt_part, $gpt_partition_size, $gpt_partition_size) = "\x00" x $gpt_partition_size;

# Update CRC32 for partitions array
my $parts_crc32 = crc32($gpt_part);
putUInt32($gpt_header, 0x58, $parts_crc32);

# Update CRC32 for GPT header itself
putUInt32($gpt_header, 0x10, 0);
putUInt32($gpt_header, 0x10, crc32(substr($gpt_header, 0, $gpt_header_size)));

# Write the updated GPT header back
seek($file, 512, SEEK_SET) or die "Failed to position at the LBA 1: $!";
print $file $gpt_header;

# Write the partitions array
seek($file, $gpt_partitions_lba * 512, SEEK_SET) or die "Failed to position at the GPT partitions array (LBA $gpt_partitions_lba): $!";
print $file $gpt_part;

# Read the backup GPT header and get the required fields again
seek($file, $gpt_backup_lba * 512, SEEK_SET) or die "Failed to position at the backup GPT header (LBA $gpt_backup_lba): $!";
read($file, $gpt_header, 512) or die "Failed to read the backup GPT sector: $!";

# Do not reread the backup GPT address: it points back to the primary one
$gpt_header_size =    getUInt32($gpt_header, 0x0c); # Size of the header in bytes (normally, 92)
$gpt_partitions_lba = getUInt64($gpt_header, 0x48); # LBA address of the partitions array
$gpt_partitions_num = getUInt32($gpt_header, 0x50); # Number of partition entries (usually, 128)
$gpt_partition_size = getUInt32($gpt_header, 0x54); # Size of a single partition entry (usually, 128 bytes)

# Update CRC32 for partitions array
putUInt32($gpt_header, 0x58, $parts_crc32);

# Update CRC32 for GPT header itself
putUInt32($gpt_header, 0x10, 0);
putUInt32($gpt_header, 0x10, crc32(substr($gpt_header, 0, $gpt_header_size)));

# Write the partitions array
seek($file, $gpt_partitions_lba * 512, SEEK_SET) or die "Failed to position at the GPT partitions array (LBA $gpt_partitions_lba): $!";
print $file $gpt_part;

# Write the backup GPT header
seek($file, $gpt_backup_lba * 512, SEEK_SET) or die "Failed to position at the backup GPT header (LBA $gpt_backup_lba): $!";
print $file $gpt_header;

print "GPT table updated.\n";

close($file);
