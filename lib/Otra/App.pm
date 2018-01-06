# -*- cperl -*-
package Otra::App;
use strict;
use warnings;

use Moo;
use File::Slurp;
use POSIX 'setsid';
use Tk;

has install_dir => (is => 'ro', required => 1);

has log_file => (is => 'ro', lazy => 1, builder => 1);
sub _build_log_file {
    my ($self) = @_;
    return $self->install_dir . "/logs/otra_app.log";
}

sub start {
    my ($self) = @_;
    $self->log("Started");

    $self->daemonize() if !$ENV{DEBUG};

    my $mw = MainWindow->new(-title => "Otra");
    $mw->Frame(-width => 640, -height => 480);
    MainLoop();
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

    append_file($self->log_file, $msg);
}


1;
