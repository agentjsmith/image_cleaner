#!/usr/bin/env perl

use warnings;
use strict;

use v5.8.0;
use sigtrap qw(die normal-signals); # make sure END block fires

##########################################################################
### These parameters may be interesting to change

# Whom to notify if something goes wrong.  Use space between multiple addresses.
my $notification_email = 'REDACTED';

# CSV file maximum age in hours.  If a CSV file is older than this, we
# will issue a warning.
my $csv_warning_hours = 48;

# Allow this script to delete images, even it if would remove every image
# in the feed.
my $overconfident = 0;

# A regular expression that matches the inventory file in the directory
my $inventory_file_pattern = qr/(?i)\.csv$/; # (ends with .csv, any case)

# A regular expression that all image files will match
my $image_file_pattern = qr/(?i)\.jpg$/; # (ends with .jpg, any case)

# A regular expression that extracts the stock number from an image
# file's name.  Must contain one () capture group around the stock number.
my $stock_number_pattern = qr(^([^_]+)_); #(beginning until the first _)

# The name of the subdirectory of the feed directory in which to store
# trash images
my $trash_subdirectory_name = ".trash";

##########################################################################

use File::stat;

my @messages = (); # A queue of error/warning messages generated throughout the process

sub send_mail {
   use Net::SMTP;
   use MIME::Base64;

   my $smtp = Net::SMTP->new(
         'mail.example.com' ,
         Hello => 'mail.example.com',
         Timeout => 30,
         Debug   => 0,
      ) or die "No connection";

   $smtp->datasend("AUTH LOGIN\n");
   $smtp->response();

   #  -- Enter sending email box address username below.  We will use this to login to SMTP --
   $smtp->datasend(encode_base64('REDACTED') );
   $smtp->response();

   #  -- Enter email box address password below.  We will use this to login to SMTP --
   $smtp->datasend(encode_base64('REDACTED') );
   $smtp->response();

   #  -- Enter email FROM below.   --
   $smtp->mail('error-reports@example.com');

   #  -- Enter email TO below --
   for my $addy (split / /,$notification_email) {
      $smtp->to($addy);
   }

   $smtp->data();

   #This part creates the SMTP headers you see
   $smtp->datasend("To: Error Report Recipients\n");
   $smtp->datasend("From: Error Reports <error-reports\@example.com>\n");
   $smtp->datasend("Content-Type: text/plain\n");
   $smtp->datasend("Subject: Image Cleaner $0 $ARGV[0]\n");

   # line break to separate headers from message body
   $smtp->datasend("\n");
   $smtp->datasend("Help!  I need an adult!\n");
   $smtp->datasend("\n");

   for my $msg (@messages) {
      $smtp->datasend($msg."\n");
   }

   $smtp->dataend();
   $smtp->quit;
}

# END block - Called when program terminates, happily or otherwise.  Generate email if any messages
#             need to be reported.
END {
  if (@messages) {
   send_mail();
  }
}

# report_error - Add an error message to the message list for emailing and terminate the run.
# Arguments: error - A human-readable string describing the problem
# Returns: n/a
sub report_error { 
   my ($error) = @_;
   
   print STDERR "ERROR: $error\n";
   push @messages, "ERROR: $error\n";
   exit 1;
}


# report_warning - Add a warning message to the message list for emailing at the end.
# Arguments: error - A human-readable string describing the problem
# Returns: n/a
sub report_warning { 
   my ($warning) = @_;
   
   push @messages, "Warning: $warning\n";
}


# load_stocks_from_homenet_csv - Read a file in HomeNet CSV format and build a hash with a key for each vehicle's stock number.
# Arguments: filename - Absolute path to file in HomeNet CSV format.  Stock Number is the 3rd column from the start.
# Returns: A hash containing each stock number found as a key. 
# Assumptions: No field before the stock number contains a comma in the value 
sub load_stocks_from_homenet_csv {
   my ($filename) = @_;

   # Ensure that the file is readable and report an error otherwise
   if (! -r $filename) {
      report_error("$filename does not exist or I do not have permission to read it.");
   }

   # Calculate the age of the file and warn if older than the threshold
   my $status = stat($filename);
   my $age = time() - $status->mtime;
   my $threshold = $csv_warning_hours * 60 * 60; # turn those hours into seconds

   if ($age > $threshold) {
      report_warning("$filename has not been updated in over $csv_warning_hours hours");
   }

   my $result = open( my $inventory_fh, "<", $filename );
   if (!$result) { # something bad happened
      report_error("Unable to open $filename for reading: $!");
   }

   # Read the contents of the CSV file and populate a hash reference
   my %vehicles = ();

   <$inventory_fh>; # Throw away the first line, which is a header
   while( my $record = <$inventory_fh> ) {
      chomp $record;
      my @fields = split /,/, $record; # Split on comma
      my $stock = $fields[2];
      $stock =~ tr/\"//d; # strip quotes
      $vehicles{$stock}++;
   }

   close $inventory_fh;
   return %vehicles;
}

# scan_directory - Generate a list of the files in the given directory that match the given regex
# Arguments: pattern - a regular expression matching the desired files, the needle
#            directory - a place to search, the haystack
# Returns: A list of filenames matching the pattern
sub scan_directory {
   my ($pattern, $directory) = @_;

   my @found = ();

   my $result = opendir( my $dh, $directory );
   if (! $result) {
      report_error("Unable to scan $directory for files: $!");
   }

   while (my $candidate_file = readdir($dh)) {
      if ($candidate_file =~ /$pattern/) { # this is a matching image file
         push @found, $directory."/".$candidate_file; 
      }
   }

   closedir( $dh );
   return @found;
}

# stock_number_from_image - Parse an image file name, returning the stock number
# Arguments: image_name - filename of the image file
# Returns: A string containing the stock number of the vehicle corresponding to this image file
sub stock_number_from_image {
   my ($image_name) = @_;

   $image_name =~ s{^.*\/}{}; # delete path name
   $image_name =~ m/$stock_number_pattern/;
   return $1 || "";
}

# find_unmatched_images - Generate a list of images that do not have entries in the hash
# Arguments: ref_image_list - reference to a list of all images to search
#            ref_valid_hash - reference to a hash containing an entry with each valid stock number as key
# Returns: A list containing the members of image_list that do not occur in valid_hash.
sub find_unmatched_images {
   my ($ref_image_list, $ref_valid_hash) = @_;

   return grep {! $ref_valid_hash->{stock_number_from_image($_)} } @$ref_image_list;
}

## Check the command line
my $feed_directory = $ARGV[0];
if (!$feed_directory || $feed_directory eq "") {
   report_error("Usage: image_cleaner.pl /path/to/feed/directory")
}

## Find the inventory CSV file
my @csv_files = scan_directory( $inventory_file_pattern, $feed_directory );
my $num_csv_files = scalar( @csv_files );

if ($num_csv_files < 1) {
   report_error("No inventory CSV file found.");
} elsif ($num_csv_files > 1) {
   report_error("Multiple inventory CSV files found.");
}

# Since there is only one, use it.
my $csv_file = $csv_files[0];

my %stock_number_lookup = load_stocks_from_homenet_csv( $csv_file );
my $loaded_vehicle_count = scalar( keys %stock_number_lookup );

if ($loaded_vehicle_count <= 0) {
   report_error("No vehicles found in CSV file.  Will not remove images.");
}

my @images = scan_directory( $image_file_pattern, $feed_directory );

## Clear trash folder, creating if it does not exist
my $trash_sub = $feed_directory . "/" . $trash_subdirectory_name;

if (! -e $trash_sub ) { # does not exist, create
   mkdir($trash_sub) or report_error("Unable to create trash directory $trash_sub: $!");
}

my @trash_to_take_out = scan_directory( qr{.*}, $trash_sub );

for my $trash (@trash_to_take_out) {
   if (-f $trash) { # only delete regular files
      unlink $trash or report_warning("Unable to delete $trash: $!");
   }
}

## Move expired files into the trash

my @deletion_candidates = find_unmatched_images( \@images, \%stock_number_lookup );
if ( ! @deletion_candidates or scalar(@deletion_candidates) <= 0 ) {
   exit 0;
}

# Don't delete every image, something may have gone wrong
if ( !$overconfident && scalar(@deletion_candidates) == scalar(@images) ) {
   report_error("Cleanup would have deleted every image; chickening out instead.  Set \$overconfident to 1 to disable this check.");
}

for my $victim (@deletion_candidates) {
   my $basename = $victim;
   $basename =~ s{^.*\/}{}; # delete path
   my $newname = $trash_sub . "/" . $basename;
   rename($victim, $newname) or report_warning("Moving $victim to $newname failed: $!");
}

