#!/usr/bin/perl -w

# Copyright 2013 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You may not 
# use this file except in compliance with the License. A copy of the License 
# is located at
#
#        http://aws.amazon.com/apache2.0/
#
# or in the "LICENSE" file accompanying this file. This file is distributed 
# on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either 
# express or implied. See the License for the specific language governing 
# permissions and limitations under the License.

our $usage = <<USAGE;

Usage: mon-put-instance-data.pl [options]

  Collects memory, swap, and disk space utilization on an Amazon EC2
  instance and sends this data as custom metrics to Amazon CloudWatch.

Description of available options:

  --mem-util          Reports memory utilization in percentages.
  --mem-used          Reports memory used in megabytes.
  --mem-avail         Reports available memory in megabytes.
  --swap-util         Reports swap utilization in percentages.
  --swap-used         Reports allocated swap space in megabytes.
  --disk-path=PATH    Selects the disk by the path on which to report.
  --disk-space-util   Reports disk space utilization in percentages.  
  --disk-space-used   Reports allocated disk space in gigabytes.
  --disk-space-avail  Reports available disk space in gigabytes.
  --load-average      Reports load average per cpu core
  --cpu-detail        Reports detalied average usage of each core since last run
  --network-util      Reports detailed average tarffic of each interface since last run
  
  --aggregated[=only]    Adds aggregated metrics for instance type, AMI id, and overall.
  --auto-scaling[=only]  Adds aggregated metrics for Auto Scaling group.
                         If =only is specified, reports only aggregated metrics.

  --mem-used-incl-cache-buff  Count memory that is cached and in buffers as used.
  --memory-units=UNITS        Specifies units for memory metrics.
  --disk-space-units=UNITS    Specifies units for disk space metrics.
  
    Supported UNITS are bytes, kilobytes, megabytes, and gigabytes.

  --aws-credential-file=PATH  Specifies the location of the file with AWS credentials.
  --aws-access-key-id=VALUE   Specifies the AWS access key ID to use to identify the caller.
  --aws-secret-key=VALUE      Specifies the AWS secret key to use to sign the request.
  --aws-iam-role=VALUE        Specifies the IAM role name to provide AWS credentials.

  --from-cron  Specifies that this script is running from cron.
  --verify     Checks configuration and prepares a remote call.
  --verbose    Displays details of what the script is doing.
  --version    Displays the version number.
  --help       Displays detailed usage information.
  
Examples
 
 To perform a simple test run without posting data to Amazon CloudWatch
 
  ./mon-put-instance-data.pl --mem-util --verify --verbose
 
 To set a five-minute cron schedule to report memory and disk space utilization to CloudWatch
  
  */5 * * * * ~/aws-scripts-mon/mon-put-instance-data.pl --mem-util --disk-space-util --disk-path=/ --from-cron

For more information on how to use this utility, see Amazon CloudWatch Developer Guide at
http://docs.amazonwebservices.com/AmazonCloudWatch/latest/DeveloperGuide/mon-scripts-perl.html

USAGE

use strict;
use warnings;
use Switch;
use Getopt::Long;
use File::Basename;
use Sys::Hostname;
use Sys::Syslog qw(:DEFAULT setlogsock);
use Sys::Syslog qw(:standard :macros);

BEGIN
{
  my $script_dir = &File::Basename::dirname($0);
  push @INC, $script_dir;
}

use CloudWatchClient;

use constant
{
  KILO => 1024,
  MEGA => 1048576,
  GIGA => 1073741824,
};

my $version = '1.1.0';
my $client_name = 'CloudWatch-PutInstanceData';

my $mcount = 0;
my $report_mem_util;
my $report_mem_used;
my $report_mem_avail;
my $report_swap_util;
my $report_swap_used;
my $report_disk_util;
my $report_disk_used;
my $report_disk_avail;
my $load_average_option;
my $cpu_detail_option;
my $network_util_option;
my $mem_used_incl_cache_buff;
my @mount_path;
my $mem_units;
my $disk_units;
my $mem_unit_div = 1;
my $disk_unit_div = 1;
my $aggregated; 	 
my $auto_scaling; 	 
my $from_cron;
my $verify;
my $verbose;
my $show_help;
my $show_version;
my $enable_compression;
my $aws_credential_file;
my $aws_access_key_id;
my $aws_secret_key;
my $aws_iam_role;
my $parse_result = 1;
my $parse_error = '';
my $argv_size = @ARGV;
my $temp_metric_name;

{
  # Capture warnings from GetOptions
  local $SIG{__WARN__} = sub { $parse_error .= $_[0]; };

  $parse_result = GetOptions(
    'help|?' => \$show_help,
    'version' => \$show_version,
    'mem-util' => \$report_mem_util,
    'mem-used' => \$report_mem_used,
    'mem-avail' => \$report_mem_avail,
    'swap-util' => \$report_swap_util,
    'swap-used' => \$report_swap_used,
    'disk-path:s' => \@mount_path,
    'disk-space-util' => \$report_disk_util,
    'disk-space-used' => \$report_disk_used,
    'disk-space-avail' => \$report_disk_avail,
    'load-average' => \$load_average_option,
    'cpu-detail' => \$cpu_detail_option,
    'network-util' \$network_util_option,
    'auto-scaling:s' => \$auto_scaling,
    'aggregated:s' => \$aggregated,
    'memory-units:s' => \$mem_units,
    'disk-space-units:s' => \$disk_units,
    'mem-used-incl-cache-buff' => \$mem_used_incl_cache_buff,
    'verify' => \$verify,
    'from-cron' => \$from_cron,
    'verbose' => \$verbose,
    'aws-credential-file:s' => \$aws_credential_file,
    'aws-access-key-id:s' => \$aws_access_key_id,
    'aws-secret-key:s' => \$aws_secret_key,
    'enable-compression' => \$enable_compression,
    'aws-iam-role:s' => \$aws_iam_role
    );

}

if (!$parse_result) {
  exit_with_error($parse_error);
}
if ($show_version) {
  print "\n$client_name version $version\n\n";
  exit 0;
}
if ($show_help || $argv_size < 1) {
  print $usage;
  exit 0;
}
if ($from_cron) {
  $verbose = 0;
}

# check for empty values in provided arguments
if (defined($aws_credential_file) && length($aws_credential_file) == 0) {
  exit_with_error("Path to AWS credential file is not provided.");
}
if (defined($aws_access_key_id) && length($aws_access_key_id) == 0) {
  exit_with_error("Value of AWS access key id is not specified.");
}
if (defined($aws_secret_key) && length($aws_secret_key) == 0) {
  exit_with_error("Value of AWS secret key is not specified.");
}
if (defined($mem_units) && length($mem_units) == 0) {
  exit_with_error("Value of memory units is not specified.");
}
if (defined($disk_units) && length($disk_units) == 0) {
  exit_with_error("Value of disk space units is not specified.");
}
if (defined($aws_iam_role) && length($aws_iam_role) == 0) {
  exit_with_error("Value of AWS IAM role is not specified.");
}

# check for inconsistency of provided arguments
if (defined($aws_credential_file) && defined($aws_access_key_id)) {
  exit_with_error("Do not provide AWS credential file and AWS access key id options together.");
}
elsif (defined($aws_credential_file) && defined($aws_secret_key)) {
  exit_with_error("Do not provide AWS credential file and AWS secret key options together.");
}
elsif (defined($aws_access_key_id) && !defined($aws_secret_key)) {
  exit_with_error("AWS secret key is not specified.");
}
elsif (!defined($aws_access_key_id) && defined($aws_secret_key)) {
  exit_with_error("AWS access key id is not specified.");
}
elsif (defined($aws_iam_role) && defined($aws_credential_file)) {
  exit_with_error("Do not provide AWS IAM role and AWS credential file options together.");
}
elsif (defined($aws_iam_role) && defined($aws_secret_key)) {
  exit_with_error("Do not provide AWS IAM role and AWS access key id/secret key options together.");
}

# decide on the reporting units for memory and swap usage
if (!defined($mem_units) || lc($mem_units) eq 'megabytes') {
  $mem_units = 'Megabytes';
  $mem_unit_div = MEGA;
}
elsif (lc($mem_units) eq 'bytes') {
  $mem_units = 'Bytes';
  $mem_unit_div = 1;
}
elsif (lc($mem_units) eq 'kilobytes') {
  $mem_units = 'Kilobytes';
  $mem_unit_div = KILO;
}
elsif (lc($mem_units) eq 'gigabytes') {
  $mem_units = 'Gigabytes';
  $mem_unit_div = GIGA;
}
else {
  exit_with_error("Unsupported memory units '$mem_units'. Use Bytes, Kilobytes, Megabytes, or Gigabytes.");
}

# decide on the reporting units for disk space usage
if (!defined($disk_units) || lc($disk_units) eq 'gigabytes') {
  $disk_units = 'Gigabytes';
  $disk_unit_div = GIGA;
}
elsif (lc($disk_units) eq 'bytes') {
  $disk_units = 'Bytes';
  $disk_unit_div = 1;
}
elsif (lc($disk_units) eq 'kilobytes') {
  $disk_units = 'Kilobytes';
  $disk_unit_div = KILO;
}
elsif (lc($disk_units) eq 'megabytes') {
  $disk_units = 'Megabytes';
  $disk_unit_div = MEGA;
}
else {
  exit_with_error("Unsupported disk space units '$disk_units'. Use Bytes, Kilobytes, Megabytes, or Gigabytes.");
}

my $df_path = '';
my $report_disk_space;
foreach my $path (@mount_path) {
  if (length($path) == 0) {
    exit_with_error("Value of disk path is not specified.");
  }
  elsif (-e $path) {
    $report_disk_space = 1;
    $df_path .= ' '.$path;
  }
  else {
    exit_with_error("Disk file path '$path' does not exist or cannot be accessed.");
  }
}

if ($report_disk_space && !$report_disk_util && !$report_disk_used && !$report_disk_avail) {
  exit_with_error("Disk path is provided but metrics to report disk space are not specified.");
}
if (!$report_disk_space && ($report_disk_util || $report_disk_used || $report_disk_avail)) {
  exit_with_error("Metrics to report disk space are provided but disk path is not specified.");
}

# check that there is a need to monitor at least something
if (!$report_mem_util && !$report_mem_used && !$report_mem_avail
  && !$report_swap_util && !$report_swap_used && !$report_disk_space
  && !$load_average_option)
{
  exit_with_error("No metrics specified for collection and submission to CloudWatch.");
}

my $now = time();
my $timestamp = CloudWatchClient::get_timestamp($now);
my $instance_id = CloudWatchClient::get_instance_id();

if (!defined($instance_id) || length($instance_id) == 0) {
  exit_with_error("Cannot obtain instance id from EC2 meta-data.");
}

if ($aggregated && lc($aggregated) ne 'only') {
  exit_with_error("Unrecognized value '$aggregated' for --aggregated option.");
}
if ($aggregated && lc($aggregated) eq 'only') {
  $aggregated = 2;
}
elsif (defined($aggregated)) {
  $aggregated = 1;
}

my $image_id;
my $instance_type;
if ($aggregated) {
  $image_id = CloudWatchClient::get_image_id();
  $instance_type = CloudWatchClient::get_instance_type();
}

if ($auto_scaling && lc($auto_scaling) ne 'only') {
  exit_with_error("Unrecognized value '$auto_scaling' for --auto-scaling option.");
}
if ($auto_scaling && lc($auto_scaling) eq 'only') {
  $auto_scaling = 2;
}
elsif (defined($auto_scaling)) {
  $auto_scaling = 1;
}

my $as_group_name;
if ($auto_scaling)
{
  my %opts = ();
  $opts{'aws-credential-file'} = $aws_credential_file;
  $opts{'aws-access-key-id'} = $aws_access_key_id;
  $opts{'aws-secret-key'} = $aws_secret_key;
  $opts{'verbose'} = $verbose;
  $opts{'verify'} = $verify;
  $opts{'user-agent'} = "$client_name/$version";
  $opts{'aws-iam-role'} = $aws_iam_role;
  
  my ($code, $reply) = CloudWatchClient::get_auto_scaling_group(\%opts);

  if ($code == 200) {
    $as_group_name = $reply;
  }
  else {
    report_message(LOG_WARNING, "Failed to call EC2 to obtain Auto Scaling group name. ".
      "HTTP Status Code: $code. Error Message: $reply");
  }

  if (!$as_group_name)
  {
    if (!$verify)
    {
      report_message(LOG_WARNING, "The Auto Scaling metrics will not be reported this time.");
      
      if ($auto_scaling == 2) {
        print("\n") if (!$from_cron);
        exit 0;
      }
    }
    else {
      $as_group_name = 'VerificationOnly';
    }
  }
}

my %params = ();
$params{'Action'} = 'PutMetricData';
$params{'Namespace'} = 'System/Linux';

# avoid a storm of calls at the beginning of a minute
if ($from_cron) {
  sleep(rand(20));
}

# collect memory and swap metrics

if ($report_mem_util || $report_mem_used || $report_mem_avail || $report_swap_util || $report_swap_used)
{
  my %meminfo;
  foreach my $line (split('\n', `/bin/cat /proc/meminfo`)) {
    if($line =~ /^(.*?):\s+(\d+)/) {
      $meminfo{$1} = $2;
    }
  }

  # meminfo values are in kilobytes
  my $mem_total = $meminfo{'MemTotal'} * KILO;
  my $mem_free = $meminfo{'MemFree'} * KILO;
  my $mem_cached = $meminfo{'Cached'} * KILO;
  my $mem_buffers = $meminfo{'Buffers'} * KILO;
  my $mem_avail = $mem_free;
  if (!defined($mem_used_incl_cache_buff)) {
     $mem_avail += $mem_cached + $mem_buffers;
  }
  my $mem_used = $mem_total - $mem_avail;
  my $swap_total = $meminfo{'SwapTotal'} * KILO;
  my $swap_free = $meminfo{'SwapFree'} * KILO;  
  my $swap_used = $swap_total - $swap_free;
  
  if ($report_mem_util) {
    my $mem_util = 0;
    $mem_util = 100 * $mem_used / $mem_total if ($mem_total > 0);
    add_metric('MemoryUtilization', 'Percent', $mem_util);
  }
  if ($report_mem_used) {
    add_metric('MemoryUsed', $mem_units, $mem_used / $mem_unit_div);
  }
  if ($report_mem_avail) {
    add_metric('MemoryAvailable', $mem_units, $mem_avail / $mem_unit_div);
  }

  if ($report_swap_util) {
    my $swap_util = 0;
    $swap_util = 100 * $swap_used / $swap_total if ($swap_total > 0);
    add_metric('SwapUtilization', 'Percent', $swap_util);
  }
  if ($report_swap_used) {
    add_metric('SwapUsed', $mem_units, $swap_used / $mem_unit_div);
  }
}

# collect disk space metrics

if ($report_disk_space)
{
  my @df = `/bin/df -k -l -P $df_path`;
  shift @df;

  foreach my $line (@df)
  {
    my @fields = split('\s+', $line);
    # Result of df is reported in 1k blocks
    my $disk_total = $fields[1] * KILO;
    my $disk_used = $fields[2] * KILO;
    my $disk_avail = $fields[3] * KILO;
    my $fsystem = $fields[0];
    my $mount = $fields[5];
    
    if ($report_disk_util) {
      my $disk_util = 0;
      $disk_util = 100 * $disk_used / $disk_total if ($disk_total > 0);
      add_metric('DiskSpaceUtilization', 'Percent', $disk_util, $fsystem, $mount);
    }
    if ($report_disk_used) {
      add_metric('DiskSpaceUsed', $disk_units, $disk_used / $disk_unit_div, $fsystem, $mount);
    }
    if ($report_disk_avail) {
      add_metric('DiskSpaceAvailable', $disk_units, $disk_avail / $disk_unit_div, $fsystem, $mount);
    }
  }
}

# collect load average metrics

if ($load_average_option) {
    my $load_average = __get_load_average();
    add_metric('LoadAverage', 'Count', $load_average);
}

sub __get_load_average {
    my $uptime = `uptime`;
    return unless $uptime;
    chomp($uptime);

    die unless ($uptime =~ /\A.*load\s?averages?:\s?(.*)\z/);
    my $min_load_average = $1;

    my $os_type = $^O || '';
    my %type_to_delimiter = (
        'darwin' => ' ',
        'linux'  => ',',
        'other'  => ',',
    );
    my $delimiter = $type_to_delimiter{ lc($os_type) } || $type_to_delimiter{'other'};
    my @load_averages = split(/$delimiter/, $min_load_average);

    return wantarray ? @load_averages : shift @load_averages;
}

if ($cpu_detail_option){
  my @old_cores;
  my @new_cores;
  my $used;
  my $system;
  my $user;
  my $nice;
  my $iowait;
  my $irq;
  my $softirq;
  my $idle;
  my $cpu_name;
  my $total;
  my $temp_file = "/tmp/cpu_statistics.tmp";
  my $command_string;
  #if there is  file with old data we import it, if not then there will be no data added this run
  if (-e "$opt_t"){
    @old_cores= (`cat $opt_t`);
    @new_cores= `cat /proc/stat |grep cpu`;
    foreach my $current_cpu (@new_cores){
      foreach my $old_cpu (@old_cores){
      if (((split(" ",$current_cpu))[0]) eq ((split(" ",$old_cpu))[0])){
        #These intial values are wrong and will be corrected
        $cpu_name = (split(" ",$current_cpu))[0];
        $user = ((split(" ",$current_cpu))[1] - (split(" ",$old_cpu))[1]);
        $nice = ((split(" ",$current_cpu))[2] - (split(" ",$old_cpu))[2]);
        $system = ((split(" ",$current_cpu))[3] - (split(" ",$old_cpu))[3]);
        $idle = ((split(" ",$current_cpu))[4] - (split(" ",$old_cpu))[4]);
        $iowait = ((split(" ",$current_cpu))[5] - (split(" ",$old_cpu))[5]);
        $irq = ((split(" ",$current_cpu))[6] - (split(" ",$old_cpu))[6]);
        $softirq = ((split(" ",$current_cpu))[7] - (split(" ",$old_cpu))[7]);
        $used = ($user + $nice + $system + $idle + $iowait + $irq + $softirq);
        #this is the total CPU time that has passded
        $total = ($used + $idle);
        #Now we correct the values
        $user = ($user / $total) * 100;
        $nice = ($nice / $total) * 100;
        $system = ($system / $total) * 100;
        $iowait = ($iowait / $total) * 100;
        $irq = ($irq / $total) * 100;
        $softirq = ($softirq / $total) * 100;
        $used = ($used / $total) * 100;
        #Time to add the metrics
        $temp_metric_name = "$cpu_name"."_user";
        addmetric('$temp_metric_name', 'Percent', $user);
        $temp_metric_name = "$cpu_name"."_nice";
        addmetric('$temp_metric_name', 'Percent', $nice);
        $temp_metric_name = "$cpu_name"."_system";
        addmetric('$temp_metric_name', 'Percent', $system);
        $temp_metric_name = "$cpu_name"."_iowait";
        addmetric('$temp_metric_name', 'Percent', $iowait);
        $temp_metric_name = "$cpu_name"."_irq";
        addmetric('$temp_metric_name', 'Percent', $irq);
        $temp_metric_name = "$cpu_name"."_soft_irq";
        addmetric('$temp_metric_name', 'Percent', $irq);
        $temp_metric_name = "$cpu_name"."_used";
        addmetric('$temp_metric_name', 'Percent', $used);
      }
    }
    #Lastly we remove the old .tmp file
    $command_string = ("/bin/rm -f $temp_file");
  }
  #now we create new .tmp file
  $command_string = ("cat /proc/stat |grep cpu \> $temp_file");
  system($command_string);
}

if ($network_util_option){
  my @ointerfaces;
  my @tinterfaces;
  my $RX_BPS;
  my $RX_PPS;
  my $RX_EPS;
  my $RX_MPS;
  my $TX_BPS;
  my $TX_PPS;
  my $TX_EPS;
  my $interfacename;
  my $opt_t = "/tmp/network_statistics.tmp";  
  my $currenttime;
  my $lastchecktime;
  my $deltatime;
  my $commandstring;
  #First we get the current time
  $currenttime = time();
  #Second we need to check if there is history file in /tmp/.If so then we pull in the data
  if (-e "$opt_t"){
    $lastchecktime = (`cat $opt_t |grep time |awk \'{print \$2}\'`);
    chomp ($lastchecktime);
    $deltatime=($currenttime - $lastchecktime);
    @ointerfaces= (`cat $opt_t`);
    ## Now we pull the current data and write it to the tmp file. 
    @tinterfaces= (`cat /proc/net/dev |grep : |awk -F : \'{print \$1" "\$2}\'|awk \'{print \$1" "\$2" "\$3" "\$4" "\$9" "\$10" "\$11" "\$12}\'`);
    foreach my $interface (@tinterfaces){
      foreach my $oldinterface (@ointerfaces){
        if (((split(" ",$interface))[0]) eq ((split(" ",$oldinterface))[0])){
          $interfacename = (split(" ",$interface))[0];
          $RX_BPS = ((split(" ",$interface))[1] - (split(" ",$oldinterface))[1]) / $deltatime;
          $RX_PPS = ((split(" ",$interface))[2] - (split(" ",$oldinterface))[2]) / $deltatime;
          $RX_EPS = ((split(" ",$interface))[3] - (split(" ",$oldinterface))[3]) / $deltatime;
          $RX_MPS = ((split(" ",$interface))[4] - (split(" ",$oldinterface))[4]) / $deltatime;
          $TX_BPS = ((split(" ",$interface))[5] - (split(" ",$oldinterface))[5]) / $deltatime;
          $TX_PPS = ((split(" ",$interface))[6] - (split(" ",$oldinterface))[6]) / $deltatime;
          $TX_EPS = ((split(" ",$interface))[7] - (split(" ",$oldinterface))[7]) / $deltatime;
          #Now we add the metrics we just calculated
          $temp_metric_name = ""$interfacename."_ReceivedBytesPerSecond";
          addmetric('$temp_metric_name', 'Bytes/Second', $RX_BPS);
          $temp_metric_name = ""$interfacename."_ReceivedPacketsPerSecond";
          addmetric('$temp_metric_name', 'Count/Second', $RX_PPS);
          $temp_metric_name = ""$interfacename."_ReceivedErrorsPerSecond";
          addmetric('$temp_metric_name', 'Count/Second', $RX_EPS);
          temp_metric_name = ""$interfacename."_ReceivedMulticastPerSecond";
          addmetric('$temp_metric_name', 'Count/Second', $RX_MPS);
          temp_metric_name = ""$interfacename."_TransmittedBytesPerSecond";
          addmetric('$temp_metric_name', 'Bytes/Second', $TX_BPS);
          $temp_metric_name = ""$interfacename."_TransmittedPacketsPerSecond";
          addmetric('$temp_metric_name', 'Count/Second', $TX_PPS);
          $temp_metric_name = ""$interfacename."_TransmittedErrorsPerSecond";
          addmetric('$temp_metric_name', 'Count/Second', $TX_EPS);
        }  
      }
    }
  ## Next we write the data to the tmp file
  #First we wipe out the old file
  $commandstring = ("/bin/rm -f $opt_t");
  system ($commandstring);
  #Next we populate the string
  }
  $commandstring = ("/bin/echo \'time $currenttime\' \>\> $opt_t");
  system ($commandstring);
  $commandstring = ("cat /proc/net/dev |grep :|awk -F : \'{print \$1\" \"\$2}\'|awk \'{print \$1\" \"\$2\" \"\$3\" \"\$4\" \"\$9\" \"\$10\" \"\$11\" \"\$12}\' \>\> $opt_t");
  #print ("$commandstring\n");
  system ($commandstring);
}

# send metrics over to CloudWatch if any

if ($mcount > 0)
{
  my %opts = ();
  $opts{'aws-credential-file'} = $aws_credential_file;
  $opts{'aws-access-key-id'} = $aws_access_key_id;
  $opts{'aws-secret-key'} = $aws_secret_key;
  $opts{'short-response'} = 1;
  $opts{'retries'} = 2;
  $opts{'verbose'} = $verbose;
  $opts{'verify'} = $verify;
  $opts{'user-agent'} = "$client_name/$version";
  $opts{'enable_compression'} = 1 if ($enable_compression);
  $opts{'aws-iam-role'} = $aws_iam_role;
  
  my ($code, $reply) = CloudWatchClient::call(\%params, \%opts);
  
  if ($code == 200 && !$from_cron) {
    if ($verify) {
      print "\nVerification completed successfully. No actual metrics sent to CloudWatch.\n\n";
    } else {
      print "\nSuccessfully reported metrics to CloudWatch. Reference Id: $reply\n\n";
    }
  }
  elsif ($code < 100) {
    exit_with_error("Failed to initialize: $reply");
  }
  elsif ($code != 200) {
    exit_with_error("Failed to call CloudWatch: HTTP $code. Message: $reply");
  }
}
else {
  exit_with_error("No metrics prepared for submission to CloudWatch.");
}

exit 0;

#
# Prints out or logs an error and then exits.
#
sub exit_with_error
{
  my $message = shift;
  report_message(LOG_ERR, $message);
 
  if (!$from_cron) {
    print STDERR "\nFor more information, run 'mon-put-instance-data.pl --help'\n\n";
  }

  exit 1;
}

#
# Prints out or logs a message.
#
sub report_message
{
  my $log_level = shift;
  my $message = shift;
  chomp $message;
 
  if ($from_cron)
  {
    setlogsock('unix');
    openlog($client_name, 'nofatal', LOG_USER);
    syslog($log_level, $message);
    closelog;
  }
  elsif ($log_level == LOG_ERR) {
    print STDERR "\nERROR: $message\n";
  }
  elsif ($log_level == LOG_WARNING) {
    print "\nWARNING: $message\n";
  }
  elsif ($log_level == LOG_INFO) {
    print "\nINFO: $message\n";
  }
}

#
# Adds one metric to the CloudWatch request.
#
sub add_single_metric
{
  my $name = shift;
  my $unit = shift;
  my $value = shift;
  my $mcount = shift;
  my $dims = shift;
  my $dcount = 0;

  $params{"MetricData.member.$mcount.MetricName"} = $name;
  $params{"MetricData.member.$mcount.Timestamp"} = $timestamp;
  $params{"MetricData.member.$mcount.Value"} = $value;
  $params{"MetricData.member.$mcount.Unit"} = $unit;

  foreach my $key (sort keys %$dims)
  {
    ++$dcount;
    $params{"MetricData.member.$mcount.Dimensions.member.$dcount.Name"} = $key;
    $params{"MetricData.member.$mcount.Dimensions.member.$dcount.Value"} = $dims->{$key};
  }
}

#
# Adds a metric and its aggregated clones to the CloudWatch request.
#
sub add_metric
{
  my $name = shift;
  my $unit = shift;
  my $value = shift;
  my $filesystem = shift;
  my $mount = shift;
  my $dcount = 0;

  my %dims = ();
  my %xdims = ();
  $xdims{'MountPath'} = $mount if $mount;
  $xdims{'Filesystem'} = $filesystem if $filesystem;

  my $auto_scaling_only = defined($auto_scaling) && $auto_scaling == 2;
  my $aggregated_only = defined($aggregated) && $aggregated == 2;
  
  if (!$auto_scaling_only && !$aggregated_only) {
    %dims = (('InstanceId' => $instance_id), %xdims);
    add_single_metric($name, $unit, $value, ++$mcount, \%dims);
  }
  
  if ($as_group_name) {
    %dims = (('AutoScalingGroupName' => $as_group_name), %xdims);
    add_single_metric($name, $unit, $value, ++$mcount, \%dims);
  }

  if ($instance_type) {
    %dims = (('InstanceType' => $instance_type), %xdims);
    add_single_metric($name, $unit, $value, ++$mcount, \%dims);
  }

  if ($image_id) {
    %dims = (('ImageId' => $image_id), %xdims);
    add_single_metric($name, $unit, $value, ++$mcount, \%dims);
  }

  if ($aggregated) {
    %dims = %xdims;
    add_single_metric($name, $unit, $value, ++$mcount, \%dims);
  }

  print "$name [$mount]: $value ($unit)\n" if ($verbose && $mount);
  print "$name: $value ($unit)\n" if ($verbose && !$mount);
}
