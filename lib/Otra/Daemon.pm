# -*- cperl -*-
package Otra::Daemon;

use strict;
use warnings;

use FindBin;
BEGIN { use lib("$FindBin::Bin/lib", "$FindBin::Bin/local/lib/perl5") };

use Moo;

use Digest::MD5 'md5_hex';
use File::Slurp;
use HTTP::Date;
use JSON;
use LWP::UserAgent;
use Parallel::ForkManager;
use POSIX ('setsid', 'strftime');
use Time::HiRes;

#------------
# Attributes
#------------

has install_dir => (is => 'ro', required => 1);

has pid_file => (is => 'ro', lazy => 1, builder => 1);
sub _build_pid_file {
    my ($self) = @_;
    return $self->install_dir . "/logs/otrad.pid";
}

has log_file => (is => 'ro', lazy => 1, builder => 1);
sub _build_log_file {
    my ($self) = @_;
    return $self->install_dir . "/logs/otrad.log";
}


has feeds_file => (is => 'ro', lazy => 1, builder => 1);
sub _build_feeds_file {
    my ($self) = @_;
    return $self->install_dir . "/conf/feeds.json";
}


has feeds_dir => (is => 'ro', lazy => 1, builder => 1);
sub _build_feed_dir {
    my ($self) = @_;
    return $self->install_dir . "/feeds";
}

has feeds_catalog => (is => 'rw', default => sub { [] });

sub run {
    my ($self) = @_;

    $self->log("Started");

    $self->daemonize() if !$ENV{DEBUG};

    my $update_catalog_deadline = time();
    my $update_catalog_tick = 60;

    while (1) {
        my $now = time();
        if ($now >= $update_catalog_deadline) {
            $self->update_catalog();
            $update_catalog_deadline = $now + $update_catalog_tick;
        }
        sleep(1);
    }
}


sub daemonize {
    my ($self) = @_;

    # daemonize
    chdir("/");
    open(STDIN, "<", "/dev/null");
    open(STDOUT, ">", "/dev/null");

    my $pid;
    defined($pid = fork()) || die "$!";
    exit if $pid;

    if (setsid() == -1) {
        die("setid failed");
    }

    write_file($self->pid_file, $$);
}


sub update_catalog {
    my ($self) = @_;

    $self->log("updating_catalog");

    if (!-e $self->feeds_file) {
        return;
    }

    my $feeds;
    eval {
        my $contents = read_file($self->feeds_file);
        $feeds = JSON::from_json($contents);
        1;
    } or do {
        $self->log("Feeds file " . $self->feeds_file . " could not be parsed: $@");
        return;
    };

    $self->feeds_catalog($feeds);

    my $pm = Parallel::ForkManager->new(4);

    for my $feed (@$feeds) {
        $pm->start and next;
        $self->fetch_feed($feed->{name} => $feed->{url});
        $pm->finish;
    }
}


sub fetch_feed {
    my ($self, $name => $url) = @_;
    my $md5 = md5_hex($name);

    my $start = Time::HiRes::time();
    $self->log(sprintf("Begin processing feed '%s' (md5: %s)", $name, $md5));

    my $this_feed_file = $self->install_dir . "/feeds/$md5.xml";
    my $feed_etag = $self->install_dir . "/feeds/$md5.etag";
    my $feed_expires = $self->install_dir . "/feeds/$md5.expires";

    my $etag;
    if (-e $feed_etag) {
        $etag = read_file($feed_etag);
    }

    my $expires;
    if (-e $feed_expires) {
        $expires = read_file($feed_expires); # unixtimestamp
    }

    my $ua = LWP::UserAgent->new;
    $ua->agent("Otra/1.0");
    $ua->timeout(10);

    $self->log("Feed $url");

    if (defined $etag) {
        my $response = $ua->head($url);

        if ($response->is_success) {
            my $this_etag = $response->header("ETag");
            if (defined $this_etag && $this_etag eq $etag) {
                $self->log("Feed $url has not changed");
                return;
            }

        } else {
            $self->log("HEAD '$url' failed: " . $response->status_line);
            return;
        }
    }

    if (defined $expires) {
        my $response = $ua->head($url);

        if ($response->is_success) {
            my $this_expires = $response->header("Expires");
            if (defined $this_expires) {
                eval {
                    $this_expires = str2time($this_expires);
                    my $now = strftime("%s", gmtime());
                    if ($this_expires > $now) {
                        $self->log("Feed $url has not expired yet");
                        return;
                    }
                };

        } else {
            $self->log("HEAD '$url' failed: " . $response->status_line);
            return;
        }

    }
    my $response = $ua->get($url);

    if ($response->is_success) {
        write_file($this_feed_file, $response->content);
        $self->log(sprintf("Wrote $md5.xml: %0.2f KB; Fetch took %0.2f seconds",
                           (-s $this_feed_file)/1024.0,
                           ((Time::HiRes::time() - $start)/10)
                          )
                  );

        # Write out etag to file
        if ($response->header("Expires")) {
            write_file($feed_expires, time2str($response->header("Expires")));
        } elsif ($response->header("ETag")) {
            write_file($feed_etag, $response->header("ETag"));
        }
    } else {
        $self->log("GET '$url' failed: " . $response->status_line);
    }
}


sub log {
    my ($self) = shift;

    if (-s $self->log_file > 2_000_000) {
        my $rotate = $self->log_file . ".1";
        if (-e $rotate) {
            unlink $rotate;
        }
        rename $self->log_file, $rotate;
    }

    my $msg = sprintf("%s %s\n", scalar(localtime()), join(" ", @_));

    append_file($self->log_file, $msg);
}


1;
