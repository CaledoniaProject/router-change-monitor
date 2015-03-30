#!/usr/bin/perl

use strict;
use warnings;
use feature 'say';
use lib '/secure/Common/src/cpan';
use lib '/home/c0debreak/perl5/lib/perl5/';

use Net::Interface;
use IO::Socket::Netlink::Route;
use Geo::IP;
use Socket;
use Socket::Netlink qw( :DEFAULT );
use Socket::Netlink::Route qw( :DEFAULT );
use LWP::UserAgent;
use File::Slurp qw/write_file/;
use Fcntl ':flock';
use threads;
use threads::shared;

INIT {
	open *{0} or die "Locked $!";
	if ( ! flock *{0} , LOCK_EX | LOCK_NB ) {
		die "$0 is running somewhere !";
	}

    $ENV{XAUTHORITY} = "/home/c0debreak/.Xauthority";
    $ENV{TERM} = "xterm";
    $ENV{DISPLAY} = ":0";
}

my @sources = qw|http://checkip.dyndns.com|;
my %ignores = map { $_ => 1 } qw/virbr0 vboxnet0/;

#### FUNCS ####


my $rtnlsock = IO::Socket::Netlink::Route->new (
    Groups => RTMGRP_IPV4_ROUTE,
) or die "Cannot make netlink socket - $!";
my @thrs = ();
my $timer :shared = 3;

push @thrs, threads->create (\&query);

while ($rtnlsock->recv_nlmsg (my $message, 8192)) {
    if ($message->nlmsg_type == NLMSG_ERROR) {
        $! = -(unpack "i!", $message->nlmsg)[0];
        say 'Error:', $!;
    }
    elsif ($message->nlmsg_type == RTM_NEWROUTE or $message->nlmsg_type == RTM_DELROUTE) {
        $timer = 1;
    }
}

$_->exit (0) for @thrs;

#######

sub gateway
{
    my ($dev, $gw);

    open my $iproute, 'ip route get 8.8.8.8 2>&1|' or next;
    chomp (my $line = <$iproute>);
    close $iproute;

    # 8.8.8.8 via 1.2.3.4 dev ppp0  src 172.16.1.35
    if ($line =~ /[^ ]+ \s+ via \s+ ([^\s]+) \s+ dev \s+ ([^\s]+) \s+ src \s+ [^\s]+/x)
    {
        ($dev, $gw) = ($1, $2);
    }
    # 8.8.8.8 dev ppp0  src 172.16.1.35
    elsif ($line =~ /[^ ]+ \s+ dev \s+ ([^\s]+) \s+ src \s+ ([^\s]+)/x)
    {
        ($dev, $gw) = ($1, $2);
    }

    return $dev, $gw;
}

sub pubip 
{
    my $ua  = LWP::UserAgent->new (agent => 'Mozilla/4.0', timeout => 3);
    my $res = $ua->get ($sources[ rand $#sources ]);

    if ($res->is_success && $res->content =~ /([0-9.]+)/)
    {
       return $1;
    }

    return undef;
}

sub message
{
    my ($msg) = @_;
    system ("notify-send", $msg);
}

sub conky
{
    my ($ip) = @_;
    write_file ('/run/shm/cache/public', '${color}IP ${color white}' . $ip . '${color}');
}

sub query
{
    my $last_gw;
    my $geo = Geo::IP->new();

    while (1)
    {
        print "Timer: $timer\n";

        if ($timer eq 0)
        {
            $timer = -1;

            my ($dev, $gw) = gateway;
            system ("notify-send", "You're disconnected"), next if not defined $dev;
            next if $dev eq 'vboxnet0' or $dev eq 'virbr0';

            my ($ip) = pubip;
            if (not defined $ip)
            {
                if (! $last_gw)
                {
                    $last_gw = $gw;
                    system ("notify-send", "Gateway changed to $gw ($dev)");
                }

                conky ("Fetching");
                $timer = 3; next;
            }

            $ip = $ip . ' - ' . $geo->country_code_by_addr ($ip);
            
            message ("PUB: $ip");
            write_file ('/run/shm/cache/public', '${color}IP ${color white}' . $ip . '${color}');
        }
        elsif ($timer > 0)
        {
            -- $timer;
        }

        sleep 1;
    }

}
