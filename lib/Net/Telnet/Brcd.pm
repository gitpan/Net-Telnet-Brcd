#!/usr/local/bin/perl
# @(#)Brcd.pm	1.9

package Net::Telnet::Brcd;

use 5.008;
use Net::Telnet;
use Carp;
use Data::Dumper;
use Socket;

use strict;
use constant DEBUG => 0;

use base qw(Net::Brcd Exporter);

# Variables de gestion du package

our $VERSION      = ('1.9' =~ m/\d/) ? '1.9' * 0.1 : 0.001;

# Variables privées
my $_brcd_prompt     = '\w+:\w+>\s+';
my $_brcd_commit     = 'yes, y, no, n';
my $_brcd_continue   = 'Type <CR> to continue, Q<CR> to stop:';
my $_brcd_prompt_re  = "/(?:${_brcd_prompt}|${_brcd_continue}|${_brcd_commit})/";
my $_brcd_timeout    = 20; # secondes

sub new {
    my ($class)=shift;

    my $self  = $class->SUPER::new();
    bless $self, $class;
    return $self;
}

sub proto_connect {
    my ($self, $switch, $user, $pass) = @_;
    
    my $proto = new Net::Telnet (Timeout => ${_brcd_timeout},
                                 Prompt  => "/${_brcd_prompt}/",
                                 );
    $proto->errmode("return");
    unless ($proto->open($switch)) {
        croak __PACKAGE__,": Cannot open connection with '$switch': $!\n";
    }
    unless ($proto->login($user, $pass)) {
        croak __PACKAGE__,": Cannot login as $user/*****: $!\n";
    }
    $self->{PROTO} = $proto;
    
    # Retourne l'objet TELNET
    return $proto;
}


sub cmd {
    my ($self, $cmd, @cmd)=@_;
    
    DEBUG && warn "DEBUG: $cmd, @cmd\n";
    
    my $proto = $self->{PROTO} or croak __PACKAGE__, ": Error - Not connected.\n";
    
    if (@cmd) {
        $cmd .= ' "' . join('", "', @cmd) . '"';
    }
    $self->sendcmd($cmd);
    #sleep(1); # Temps d'envoi de la commande

    # Lecture en passant les continue
    @cmd = ();
    CMD: while (1) {
       my ($str, $match) = $proto->waitfor(${_brcd_prompt_re});

       DEBUG && warn "DEBUG:: !$match!$str!\n";
       push @cmd, split m/[\n\r]+/, $str;
       if ($match eq ${_brcd_commit}) {
            $proto->print('yes');
            next CMD;
       }
       if ($match eq ${_brcd_continue}) {
          $proto->print("");
          next CMD;
       }
       last CMD;
    }
    @cmd = grep {defined $_} @cmd;

    $self->{OUTPUT} = \@cmd;

    return @cmd;
}

sub sendcmd {
    my ($self, $cmd) = @_;
    
    my $proto = $self->{PROTO} or croak __PACKAGE__, ": Error - Not connected.\n";
    
    DEBUG && $proto->dump_log("/tmp/telnet.log");
    DEBUG && warn "Execute: $cmd\n";
    
    unless ($proto->print($cmd)) {
        croak __PACKAGE__,": Cannot send '$cmd': $!\n";
    }
    return 1;
}

sub sendeof {
    my ($self) = @_;
    
    my $proto = $self->{PROTO} or croak __PACKAGE__, ": Error - Not connected.\n";

    unless ($proto->print("\cD")) {
        croak __PACKAGE__,": Cannot Ctrl-D: $!\n";
    }
    return 1;
}

sub readline {
    my ($self, $arg_ref) = @_;  

    #my ($str, $match) = $proto->waitfor(m/^\s+/);
    my $proto = $self->{PROTO} or croak __PACKAGE__, ": Error - Not connected.\n";
    #DEBUG && warn "DEBUG:: <$str>:<$match>\n";
    #return $str;
    my $str = $proto->getline(($arg_ref?%{$arg_ref}:undef));
    if ($str =~ m/{_brcd_prompt_re}/) {
        return;
    }
    return $str;
}

sub DESTROY {
    my $self = shift;

    $self->{PROTO}->close() if exists $self->{PROTO};
}


1;

__END__

=pod

=head1 NAME

Net::Telnet::Brcd - Perl libraries to contact Brocade switch

=head1 SYNOPSIS

    use Net::Telnet::Brcd;
    
    my $sw = new Net::Telnet::Brcd;
    
    $sw->connect($sw_name,$user,$pass) or die "\n";
    
    %wwn_port = $sw->switchShow(-bywwn=>1);
    my @lines = $sw->cmd("configShow");

=head1 DESCRIPTION

Perl libraries to contact Brocade switch with a telnet session. You could set this
environment variable to simplify coding:

=over 4

=item C<BRCD_USER>

login name

=item C<BRCD_PASS>

login password

=item C<BRCD_SWITCH>

switch name or IP address

=back

=head1 FUNCTIONS

=head2 new

    my $brcd = new Net::Telnet::Brcd;

Initialize Brocade object. No arguments needed.

=head2 connect

    $brcd->connect($switch,$user,$pass);

Connect to a Brocade switch with a telnet session (use Net::Telnet module). Return undef on error.
Do it before any switch command.

The Net::Telnet object is stored in $brcd->{TELNET}. You could access Net::Telnet capabilities with 
this object.

One object is required for each connection. If you want simultaneous connection
you need several objects.

=head2 cmd

    my @results = $brcd->cmd("configShow");
    my $ok      = $brcd->cmd("cfgsave");

This function is used to send command to a brocade switch. The command works as the 'cmd' 
function of Net::Telnet module and add differents features:

=over

=item *

The command set the regular expression for Brocade prompt.

=item *

The command tracks the continue question and answer 'yes'.
The goal of this module is to be used in silent mode.

=item *

The Brocade command answer is returned without carriage return (no \r \n).

=item *

Two methods is used to give parameters.

scalar: The string command is sent as is.

array: The command thinks that the first element is a command, the second
the principal arguments and other members. It is very useful for ali* command.

=back

Examples :

    my @results=$brcd->cmd("aliAdd","toto",":00:00:0:5:4:54:4:5");
    aliAdd "toto", "00:00:0:5:4:54:4:5"

The command does not decide that the command answer is an error or not. It just
store the stdout of the brocade command and return it in a array.

=head2 sendcmd

    my $rc = $brcd->sendcmd("portperfshow");

This function execute command without trap standard output. It's useful for 
command that needs to be interrupted.

You have to use the C<readline> function to read each line generated by the command.

=head2 sendeof

    my $rc = $brcd->sendeof();

Send Ctrl-D command to interrupt command (useful for portperfshow).

=head2 readline

    while (my ($str) = $brcd->readline()) {
        # Do what you want with $str
    }

Read telnet output as piped command. You have a to decided when to stop (If the line 
content a prompt, I return undef). The command accept the same argument as Net::Telnet getline command.

    $brcd->readline({Timeout => 60});

You have to set argument with a hash ref.

=head2 aliShow

    my %alias_to_wwn = $brcd->aliShow();

Send command C<aliShow "*"> and return a hash. Some option, change the content
of the returned hash :

=over 1

=item default

Without option : return key = alias, value = WWN. 

B<Be carefull !!> If one alias contains multiple WWN, value is a ref array of 
all the WWN member.

=item -onlywwn

With option -onlywwn => 1 (default option) : does not return alias with port 
naming. Disable this option (-onlywwn => 0), if you want both.

=item -filter

By default, -filter is set to '*'. You could use an other filter to select
specific alias. Recall of rbash regular expression, you could use in filter :

=over 2

=item *

Any character.

=item ?

One character.

=item [..]

Character class. For instance a or b => [ab]

=item Examples

    -filter => '*sv*'
    -filter => 'w_??[ed]*'

=back

=item -bywwn

With option -bywwwn => 1, return key = WWN, value = alias

    my %wwn_to_alias = $brcd->aliShow(-bywwn => 1);

=item -byport

With option -byport => 1, return key = port, value = alias

=back

=head2 zoneShow

    my %zone = $brcd->zoneShow();

Return a hash with one key is a zone and value an array of alias member or WWN or ports.

    my %zone = $brcd->zoneShow();

    foreach my $zone (%zone) {
        print "$zone:\n\t";
        print join("; ", keys %{$zone{$zone}} ),"\n";
    }
    
=over 

=item -bymember => 1

If you set option C<-bymember => 1>, you have a hash with key a member and value an array of
zones where member exists.

=item -filter   => '*'

By default, select all zone but you could set a POSIX filter for your zone.

=back

It's important to run this command before using the followings functions.

=head2 zoneMember

    my @member = $brcd->zoneMember("z_sctxp004_0");

Return an array of member of one zone. Need to execute C<$brcd->zoneShow> before.

=head2 memberZone

    my @zones = $brcd->memberZone("w_sctxp004_0");

Return an array of zones where member exist. Need to execute C<$brcd->zoneShow> before.

=head2 switchShow

    my %port = $brcd->switchShow();

This function send the switchShow command on the connected switch (see only one switch
not all the fabric). It returns the following structure:

    $port{port number}->{SPEED}  = <2G|1G|...>
                      ->{STATUS} = <OnLine|NoLight|...>
                      ->{SLOT}   = blade number
                      ->{NUMBER} = port number on blade
                      ->{TYPE}   = <E-Port|F-Port|...>
                      ->{WWN}    if connected

If you set C<-bywwn=1>, it's return only a hash of WWN as key and port number as value.

    my %wwn_to_port = $brcd->switchShow(-bywwn => 1);

If you set C<-withportname=1>, the portName command is execute on each port of the switch to get the portname.

If you set C<-byslot=1>, it's return only a hash of slot/number as key and portname and port number 
as value.

=head2 toSlot

    my ($slot,$slot_number) = $brcd->toSlot(36);
    my $slot_address        = $brcd->toSlot(36);

The function need to have an exectution of C<$brcd->switchShow>. It's usefull for
a Director Switch to have the translation between absolute port number and slot/port number value.

If you use it in scalar context, the command return the string C<slot/slot_number> (portShow format).

=head2 portShow

    my %port     = $brcd->portShow($port_number);
    my $portname = $brcd->portShow($port_number);

Need to have running the C<$brcd->switchShow> command. The function use the C<toSlot>
function before sending the portShow command.

In array context, function return a hash with key as the portName. In scalar context returns the
portname.

=head2 output

    print $brcd->output();

Return the last function output.

=head2 wwn_re

    my $wwn_re = $brcd->wwn_re();

    if (m/($wwn_re)/) {
        ...
    }

Return the WWN re.

=head2 fabricShow

    my %fabric = $brcd->fabricShow();

Return a hash with all the switch in the fabric. Return the result byswitch name C<-byswitch> or
C<-bydomain=1>.

=head2 currentFabric

    my $dns_fabric = $brcd->currentFabric();

Return the current fabric NAME.

=head2 isWwn

    if ($brcd->isWwn($str)) {
        ...
    }

Test a string to check if it is a WWN.

=head2 portAlias

    my ($domain, $port_number) = $brcd->portAlias("199,6");

Split a string whith zoning format in domain and port number in the switch.

=head2 cfgSave

    my $boolean = $brcd->cfgSave();
    
The function execute cfgSave command an return true if ok or exit. You can trap
this exception whith C<eval {};> block. Error message always begin with C<Error - >.

=head2 zone

    my @rc = $brcd->zone(
        -add     => 1,
        -name    => 'z_toto1',
        -members => '10:00:00:00:C9:3D:F3:04',
    );
        
    my @rc = $brcd->zone(
        -add     => 1,
        -name    => 'z_toto2',
        -members => [
            '10:00:00:00:C9:3D:F3:04',
            '10:00:00:00:C9:48:08:E2',
        ],
    );

Supported sub commmand are -add, -create, -delete, -remove.

=head2 ali

    my @rc = $brcd->ali(
        -create  => 1,
        -name    => 'w_toto1',
        -members => '10:00:00:00:C9:51:FB:29',
    );
        
    my @rc = $brcd->ali(
        -add     => 1,
        -name    => 'w_toto2',
        -members => [
            '10:00:00:00:C9:46:D8:FD',
            '10:00:00:00:C9:46:DA:A7',
        ],
    );
    
    my @rc = $brcd->ali(
        -add     => 1,
        -name    => 'w_toto3',
        -members => [
            '10:00:00:00:C9:46:D5:B7',
        ],
    );

Supported sub commmand are -add, -create, -delete, -remove.

=head1 SEE ALSO

Brocade Documentation, BrcdAPI, Net::Telnet.

=head1 BUGS

...

=head1 AUTHOR

Laurent Bendavid, E<lt>bendavid.laurent@fre.frE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2005 by Laurent Bendavid

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.3 or,
at your option, any later version of Perl 5 you may have available.

=over

=item Version

1.9

=item History

Created 6/27/2005, Modified 8/14/07 18:41:02

=back

=cut
