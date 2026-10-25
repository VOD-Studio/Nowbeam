#!/usr/bin/perl
use strict;
use warnings;
use DynaLoader;
use FindBin qw($RealBin);

# 资源位置由包内脚本决定；调用方不能指定任意库或播放控制命令。
my $mode = shift @ARGV // '';
die "Unsupported media operation\n" unless @ARGV == 0 && ($mode eq 'snapshot' || $mode eq 'events');
for my $key (keys %ENV) {
    delete $ENV{$key} if index($key, 'MEDIAREMOTEADAPTER_') == 0;
}
$ENV{MEDIAREMOTEADAPTER_OPTION_micros} = '';
$ENV{MEDIAREMOTEADAPTER_OPTION_no_artwork} = '';
$ENV{MEDIAREMOTEADAPTER_OPTION_no_diff} = '';
$ENV{MEDIAREMOTEADAPTER_OPTION_debounce} = '100';

my $adapter = DynaLoader::dl_load_file("$RealBin/MediaRemoteAdapter.framework/MediaRemoteAdapter", 1)
    or die "Media framework unavailable\n";
my $library = $adapter;
my $symbol = 'adapter_stream_env';
if ($mode eq 'snapshot') {
    $library = DynaLoader::dl_load_file("$RealBin/NowbeamMediaGate.dylib", 0)
        or die "Media validity bridge unavailable\n";
    $symbol = 'nowbeam_media_snapshot';
}
my $address = DynaLoader::dl_find_symbol($library, $symbol)
    or die "Media entry point unavailable\n";
my $entry = DynaLoader::dl_install_xsub('Nowbeam::read_only', $address);
$entry->();
