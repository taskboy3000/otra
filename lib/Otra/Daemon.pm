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
use Otra::Schema;
use Time::HiRes;
use XML::Feed;

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

has schema => (is => 'ro', lazy => 1, builder => 1);
sub _build_schema {
    my ($self) = @_;
    Otra::Schema->new(install_dir => $self->install_dir);
}

#--------------
# Methods
#--------------
sub run {
    my ($self) = @_;

    $self->log("Started");

    $self->daemonize() if !$ENV{DEBUG};

    if (!$self->schema->is_installed) {
        $self->schema->install();
    }

    my $update_catalog_deadline = time();
    my $update_catalog_tick = 60*5;

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

    my $max_children = $ENV{DEBUG} ? 0 : 4;

    my $pm = Parallel::ForkManager->new($max_children);

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

    $self->log("Feed URL: $url");

    if (defined $etag) {
        my $response = $ua->head($url);

        if ($response->is_success) {
            my $this_etag = $response->header("ETag");
            if (defined $this_etag && $this_etag eq $etag) {
                $self->log("Feed '$name' has not changed");
                return;
            } else {
                $self->log("Feed '$name' has a new ETag " . $response->header("Etag"));
            }

        } else {
            $self->log("HEAD '$url' failed: " . $response->status_line);
            return;
        }
    }

    if (defined $expires) {
        my $now = time();
        if ($expires > $now) {
            $self->log("Feed '$name' has not yet expired");
            return;
        } else {
            $self->log(sprintf("Feed 'name' expired %d seconds ago", ($now - $expires)));
        }
    }

    my $response = $ua->get($url);

    if ($response->is_success) {
        write_file($this_feed_file, $response->content);
        $self->log(sprintf("Caching feed '$name' with $md5.xml: %0.2f KB; Fetch took %0.2f seconds",
                           (-s $this_feed_file)/1024.0,
                           ((Time::HiRes::time() - $start)/10)
                          )
                  );

        # Write out etag to file
        if ($response->header("Expires")) {
            my $expiry = $response->header("Expires");
            my $expiry_ts = str2time($expiry);
            $self->log("Feed '$name' expires: $expiry [$expiry_ts]");
            write_file($feed_expires, $expiry_ts);
        } elsif ($response->header("ETag")) {
            $self->log("Feed '$name' has an ETag of " . $response->header("ETag"));
            write_file($feed_etag, $response->header("ETag"));
        }

        $self->import_feed($name => $response->content);
    } else {
        $self->log("GET '$url' failed: " . $response->status_line);
    }
}


sub log {
    my ($self) = shift;

    if (-e $self->log_file) {
        if (-s $self->log_file > 2_000_000) {
            my $rotate = $self->log_file . ".1";
            if (-e $rotate) {
                unlink $rotate;
            }
            rename $self->log_file, $rotate;
        }
    }

    my $msg = sprintf("%s %s\n", scalar(localtime()), join(" ", @_));

    if ($ENV{DEBUG}) {
        print STDERR $msg;
    }

    append_file($self->log_file, $msg);
}


sub import_feed {
    my ($self, $name => $feed_xml) = @_;
    return if !$name || !$feed_xml;

    my $P = XML::Feed->parse(\$feed_xml);
    if (!$P) {
        $self->log("Could not parse feed for '$name': " . XML::Feed->errstr);
        return;
    }

    my $schema = $self->schema;
    # Find or create this channel
    my $channel = $schema->orm->table("channels")->search({ name => $P->title })->single;
    if (!$channel) {
        $self->log("Creating channel " . $P->title);
        my $id = $schema->save("channels" => { name => $P->title, url => $P->link });
        $channel = $schema->orm->table("channels")->search({id => $id})->single;
    }

    my $seen = 0;
    for my $entry ($P->entries) {
        my $found = $schema->orm->table("articles")->search({url => $entry->link});
        next if $found->count;

        my $pub_date = $entry->issued || $entry->modified || 0;

        if ($pub_date) {
            $pub_date = str2time($pub_date);
        }

        my $rc = $schema->save("articles" => {
                                              channel_id => $channel->id,
                                              url => $entry->link,
                                              title => $entry->title,
                                              description => $entry->content->body, # need to parse
                                              published_at => $pub_date,
                                             });
        if (!$rc) {
            $self->log("Could not add article");
        } else {
            $seen++;
        }
    }

    $self->log(sprintf("Found %d new articles", $seen));
}


1;
