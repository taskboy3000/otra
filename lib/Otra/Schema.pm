# -*- cperl -*-
package Otra::Schema;
use strict;
use warnings;

use FindBin;
BEGIN { use lib("$FindBin::Bin/lib", "$FindBin::Bin/local/lib/perl5") };

use Moo;
use File::Slurp;
use DBI;
use DBIx::Lite;
use Data::GUID;

#------------
# Attributes
#------------

has install_dir => (is => 'ro', required => 1);

has db_name => (is => 'ro', lazy => 1, builder => 1);
sub _build_db_name {
    my ($self) = @_;
    $self->install_dir . "/data/otra.db";
}


has schema_dir => (is => 'ro', lazy => 1, builder => 1);
sub _build_schema_dir {
    my ($self) = @_;
    return $self->install_dir . "/schema";
}


has log_file => (is => 'ro', lazy => 1, builder => 1);
sub _build_log_file {
    my ($self) = @_;
    return $self->install_dir . "/logs/otra_db.log";
}


has orm => (is => 'ro', lazy => 1, builder => 1);
sub _build_orm {
    my ($self) = @_;
    DBIx::Lite->new(dbh => $self->db);
}


#------------
# Methods
#------------
sub db {
    my ($self) = @_;
    my $dbh = DBI->connect("dbi:SQLite:dbname=" . $self->db_name) or die("Connect: $DBI::errstr");
    return $dbh;
}

sub is_installed {
    my ($self) = @_;

    return (-e $self->db_name && -s $self->db_name > 0);
}

sub install {
    my ($self) = @_;

    $self->log("Installing tables into " . $self->db_name);

    my @schema_files = glob($self->schema_dir . "/*.sql");

    my $db = $self->db;
    for my $file (@schema_files) {
        $self->log("Installing $file");
        my $sql = read_file($file);
        $db->do($sql);
    }
}


sub uuid { Data::GUID->new->as_string }

sub save {
    my ($self, $table => $data) = @_;
    return unless $table;
    return unless ref $data eq 'HASH';

    delete $data->{created_at};
    delete $data->{updated_at};

    if (exists $data->{id}) {
        # update
        my $id = delete $data->{id};
        $data->{updated_at} = time();
        $self->orm->table($table)->search({id => $id})->update($data) or $self->log("Update to $table failed");
        return $id;
    } else {
        # insert
        $data->{id} = $self->uuid;
        $data->{created_at} = $data->{updated_at} = time();
        $self->orm->table($table)->insert($data) or $self->log("Insert to $table failed");
        return $data->{id};
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
