#!/usr/local/bin/perl
# @(#)Brcd.pm	1.3

package Net::Telnet::Brcd;

use 5.008;
use Net::Telnet;
use Carp;
use Data::Dumper;
use Socket;

use strict;
use constant DEBUG => 0;

require Exporter;

# Variables de gestion du package
our %EXPORT_TAGS  = ( 'all' => [ qw() ] );
our @EXPORT_OK    = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT       = qw();

our $VERSION      = 1.3 * 0.1;
our @ISA          = qw(Exporter);

# Variables privées
my $_brcd_prompt     = '\w+:\w+>\s+';
my $_brcd_continue   = 'Type <CR> to continue, Q<CR> to stop:';
my $_brcd_prompt_re  = "/(?:${_brcd_prompt}|${_brcd_continue})/";
my $_brcd_wwn_re     = join(":",("[0-9A-Za-z][0-9A-Za-z]") x 8);
my $_brcd_port_id    = qr/\d+,\d+/;
my $_brcd_timeout    = 20; # secondes

sub new {
    my ($class)=shift;

    $class   = ref($class) || $class;
    my $self = {};

    $self->{TELNET} = new Net::Telnet (Timeout => ${_brcd_timeout},
                                       Prompt  => "/${_brcd_prompt}/",
                                       );

    $self->{TELNET}->errmode("return");

    bless $self, $class;
    return $self;
}

sub connect {
    my ($self,$switch,$user,$pass)=@_;

    $user   ||= $ENV{BRCD_USER} || "admin";
    $pass   ||= $ENV{BRCD_PASS};
    $switch ||= $ENV{BRCD_SWITCH};

    unless ($switch) {
        carp __PACKAGE__,": Need switch \@IP or name.\n";
        return;
    }
    unless ($user and $pass) {
        carp __PACKAGE__,": Need user or password.\n";
        return;
    }
    unless ($self->{TELNET}->open($switch)) {
        carp __PACKAGE__,": Cannot open connection with '$switch': $!\n";
        return;
    }
    $self->{FABRICS}->{$switch}={};
    $self->{FABRIC}=$switch;
    unless ($self->{TELNET}->login($user,$pass)) {
        carp __PACKAGE__,": Cannot login as $user/*****: $!\n";
        return;
    }
    $self->{USER}=$user;

    return 1;
}

sub cmd {
    my ($self,$cmd,@cmd)=@_;
    
    if (@cmd) {
        $cmd.=" \"".join("\", \"",@cmd)."\"";
    }
    
    DEBUG && warn "Execute: $cmd\n";

    unless ($self->{TELNET}->print($cmd)) {
        carp __PACKAGE__,": Cannot send cmd '$cmd': $!\n";
        return;
    }
    # Lecture en passant les continue
    @cmd = undef;
    CMD: while (1) {
       my ($str,$match) = $self->{TELNET}->waitfor(${_brcd_prompt_re});

       push @cmd, split m/[\n\r]+/, $str;
       if ($match eq ${_brcd_continue}) {
          $self->{TELNET}->print("");
          next CMD;
       }
       last CMD;
    }

    $self->{OUTPUT}=\@cmd;

    return @cmd;
}

sub aliShow {
    my $self=shift;

    my %args=(
          -bywwn    =>  0,
          -byport   =>  0,
          -cache    =>  0,
          -onlywwn  =>  1,
          @_
          );

    my $fab_name = $self->{FABRIC};
    my $fab      = $self->{FABRICS}->{$fab_name};
    $args{-onlywwn} = 0 if $args{-byport};

    #unless ($args{'-cache'} and exists $fab->{WWN} and exists $fab->{ALIAS}) {
    my ($alias);
    $fab->{PORTID} = {};
    $fab->{WWN}    = {};
    $fab->{ALIAS}  = {};
    foreach ($self->cmd("aliShow \"*\"")) {
        next unless $_;
        if (m/alias:\s+(\w+)/) {
            $alias=$1;
            next;
        }
        if ($alias && m/(${_brcd_wwn_re})/) {
            my $wwn = $1;
            $fab->{WWN}->{$wwn}     = $alias;
            $fab->{ALIAS}->{$alias} = $wwn;
            next;
        }
        
        next if $args{-onlywwn};
        
        if ($alias && m/(${_brcd_port_id})/) {
            my $port_id = $1;
            $fab->{PORTID}->{$port_id} = $alias;
            $fab->{ALIAS}->{$alias}    = $port_id;
            next;
        }
    }
    #}
    DEBUG && warn Dumper($fab);

    return ($args{'-bywwn'})  ? (%{$fab->{WWN}})    :
           ($args{'-byport'}) ? (%{$fab->{PORTID}}) :                  
                                (%{$fab->{ALIAS}});
}

sub zoneShow {
    my $self=shift;

    my %args=(
          -bymember => 0,
          -cache    => 0,
          @_
          );

    my $fab_name = $self->{FABRIC};
    my $fab      = $self->{FABRICS}->{$fab_name};

    unless ($args{'-cache'} and exists $fab->{WWN} and exists $fab->{ALIAS}) {
        my ($zone);
        foreach ($self->cmd("zoneShow \"*\"")) {
            if (m/zone:\s+(\w+)/) {
                $zone=$1;
                next;
            }
            if ($zone && m/\s*(\w[\w\s;]+)/) {
                my $members = $1;
                my @member  = split m/;\s+/, $members;

                foreach my $member (@member) {
                    $fab->{ZONE}->{$zone}->{$member}++;
                    $fab->{MEMBER}->{$member}->{$zone}++;
                }
            }
        }
    }

    if (wantarray()) {
        return ($args{'-bymember'})?(%{$fab->{MEMBER}}):(%{$fab->{ZONE}});
    }
}

sub zoneMember {
    my ($self,$zone)=@_;

    my $fab_name = $self->{FABRIC};
    my $fab      = $self->{FABRICS}->{$fab_name};

    return unless exists $fab->{ZONE}->{$zone};

    return sort keys %{$fab->{ZONE}->{$zone}};
}

sub memberZone {
    my ($self,$member)=@_;

    my $fab_name = $self->{FABRIC};
    my $fab      = $self->{FABRICS}->{$fab_name};

    return unless exists $fab->{MEMBER}->{$member};

    return sort keys %{$fab->{MEMBER}->{$member}};
}

sub switchShow {
    my $self=shift;

    my %args=(
          -bywwn        => 0,
          -cache        => 0,
          -withportname => 0,
          @_
          );

    my $fab_name = $self->{FABRIC};
    my $fab      = $self->{FABRICS}->{$fab_name};

    my (%wwn);
    unless ($args{'-cache'} and exists $fab->{PORT}) {
        foreach ($self->cmd("switchShow")) {
            next unless $_;
DEBUG && warn  "SWITCHSHOW   : $_\n";
            if (m/^(\w+):\s+(.+)/) {
                $fab->{$1} = $2;
                next;
            }
#12000 :     0    1    0   id    2G   Online    E-Port  (Trunk port, master is Slot  1 Port
#4100  :     0   0   id    2G   Online    E-Port  10:00:00:05:1e:35:f6:e5 "PS4100A"       
#3800  :port  0: id 2G Online         F-Port 50:06:01:60:10:60:04:26
#48000 :  13    1   13   0a0d00   id    N2   Online           F-Port  10:00:00:00:c9:35:99:4b
#48000 : 12    1   12   0a0c00   id    N4   No_Light      
            if (m{
                ^[port\s]*(\d+):? \s*        # Le port number forme ok:port 1: ; 12;144
                (?:
                    (?:
                      (\d+)\s+               # Le slot que sur les directeurs
                    )?
                    (\d+)\s*                 # Le port dans le slot
                )?
                ([09a-zA-Z]+)?               # Adresse FC, que à partir de FabOS 5.2.0a
                \s+ id \s+                   # Le mot magique qui dit que c'est la bonne ligne
                [a-zA-Z]*(\d+)[a-zA-Z]*  \s+ # Vitesse du port plusieurs format à priori toujours en Go/s
                (\w+)  \s*                   # Status du port
                (.*)                         # Toutes les autres informations (notamment le WWN si connectés)
            }mxs) {
DEBUG && warn  "SWITCHSHOW-RE: #$1# #$2# #$3# #$4# #$5# #$6# #$7#\n";
                # Récupération des champs, les champs dans les même ordre que les $
                my @fields = qw(SLOT NUMBER ADDRESS SPEED STATUS INFO);              
                my $port_number  = $1;
                my $port_info    = $7;  
                foreach my $re ($2, $3, $4, $5, $6, $7) {
                    my $field = shift @fields;
                    if (defined $re) {
                        $fab->{PORT}->{$port_number}->{$field} = $re;
                    }
                }
                $fab->{PORT}->{$port_number}->{PORTNAME} = $self->portShow($port_number) if $args{-withportname};

                if ($port_info and $port_info =~ m/^(\w-\w+)\s+(${_brcd_wwn_re})?/) {
                    my ($type, $wwn) = ($1,$2);
                    $fab->{PORT}->{$port_number}->{TYPE} = $type;
                    $fab->{PORT}->{$port_number}->{WWN}  = $wwn   if $wwn;
                    

                    if ($type eq "F-Port") {
                        $wwn{$wwn} = $port_number;
                    }
                }
            }
        }
    }

    return ($args{'-bywwn'})?(%wwn):( (exists $fab->{PORT}) ? %{$fab->{PORT}} : undef);
}

sub toSlot {
    my $self        = shift;
    my $port_number = shift;
    
    my $fab_name = $self->{FABRIC};
    my $fab      = $self->{FABRICS}->{$fab_name};

DEBUG && warn "TOSLOT: $port_number\n";
    
    unless (exists $fab->{PORT}->{$port_number}) {
        $@ = __PACKAGE__.":toSlot: port number $port_number does not exist\n";
        
DEBUG && warn "$@\n";

        return;
    }
    unless (exists $fab->{PORT}->{$port_number}->{SLOT}) {
    
        $@ = __PACKAGE__.":toSlot: port number $port_number is not a director\n";
DEBUG && warn "$@\n";

        return;
    }
    
DEBUG && warn "TOSLOT: ",$fab->{PORT}->{$port_number}->{SLOT}."/".$fab->{PORT}->{$port_number}->{NUMBER},"\n";

    return (wantarray())?($fab->{PORT}->{$port_number}->{SLOT},$fab->{PORT}->{$port_number}->{NUMBER}):
                          $fab->{PORT}->{$port_number}->{SLOT}."/".$fab->{PORT}->{$port_number}->{NUMBER};
}

sub portShow {
    my $self        = shift;
    my $port_number = shift;

    my $fab_name = $self->{FABRIC};
    my $fab      = $self->{FABRICS}->{$fab_name};
    
DEBUG && warn "PORTSHOW-PORTNUMBER: $port_number\n";
       $port_number = $self->toSlot($port_number) || $port_number;
DEBUG && warn "PORTSHOW-PORTNUMBER: $port_number\n";
    my (%port, $param, $value, $portname);
    
    foreach ($self->cmd("portShow $port_number")) {
    
DEBUG && warn "PORTSHOW: $_\n";

        if (m/^([\w\s]+):\s+(.+)/) {
            $param        = $1;
            $value        = $2;
            
DEBUG && warn "PORTSHOW: param #$param# value #$value#\n";
            
            $port{$param} = $value;
            SWITCH: {
                if ($param eq 'portName') {
                    $fab->{PORT}->{$port_number}->{PORTNAME} = $value;
                    $portname                                = $value;
                    last SWITCH;
                }
            }
            next;
        }
        
        if (m/^([\w\s]+):\s*$/) {
            $param = $1;
            next;
        }
        
        if (m/^\s+(.+)/) {
            $port{$param} = $1;
            next;
        }
    }

    return (wantarray())?(%port):($portname);
}

sub output {
    my $self=shift;

    return join("\n",@{$self->{OUTPUT}})."\n";
}

sub wwn_re {
    return ${_brcd_wwn_re};
}

sub DESTROY {
    my $self=shift;

    $self->{TELNET}->close();
}

sub fabricShow {
    my $self=shift;
    my %args=(
          -bydomain        => 0,
          @_
          );
    my (%fabric,%domain);
    
    foreach ($self->cmd('fabricShow')) {
        next unless $_;
DEBUG && warn "DEBUG:: $_\n";
        if (m{
            ^\s* (\d+) : \s+ \w+ \s+  # Domain id + identifiant FC
            ${_brcd_wwn_re} \s+       # WWN switch
            (\d+\.\d+\.\d+\.\d+) \s+  # Adresse IP switch
            \d+\.\d+\.\d+\.\d+   \s+  # Adresse IP FC switch (FCIP)
            (>?)"([^"]+)              # Master, nom du switch
        }msx) {
            my ($domain_id, $switch_ip, $switch_master, $switch_name) = ($1, $2, $3, $4);
            my $switch_host = gethostbyaddr(inet_aton($switch_ip), AF_INET);
            my @fields      = qw(DOMAIN IP MASTER FABRIC NAME MASTER);
            foreach my $re ($domain_id, $switch_ip, $switch_master, $switch_host, $switch_name) {
                my $field = shift @fields;
                if ($re) {
                    $domain{$domain_id}->{$field}   = $re;
                    $fabric{$switch_name}->{$field} = $re;
                } 
            }
            
            $fabric{$switch_host} = $switch_name if $switch_host;
        }
    }
    
    return ($args{-bydomain}) ? (%domain) :
                                (%fabric);
}

sub currentFabric {
    my $self = shift;
    
    return $self->{FABRIC};
}


sub isWwn {
    my $self = shift;    
    my $wwn = shift;
    
    ($wwn =~ m/^${_brcd_wwn_re}/)?(return 1):(return);
    
}

sub portAlias {
    my $self = shift;
    my $port_alias = shift;
    
    if ($port_alias =~ m/(\d+),(\d+)/){
        return ($1, $2);
    }
    return;
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

Connect to a Brocade switch with a telnet session. Return undef on error.
Do it before any switch command.

The object '$brcd' store the telnet session. If you want simultaneous connection
you need an other object.

=head2 cmd

    my @results=$brcd->cmd("configShow");

Send a Brocade command to the switch and return all the lines. Line are cleaned (no \r \n).

If command parameters is given by array:

    my @results=$brcd->cmd("aliAdd","toto",":00:00:0:5:4:54:4:5");

The command generated are:

    aliAdd "toto", ":00:00:0:5:4:54:4:5"

=head2 aliShow

    my %alias_to_wwn = $brcd->aliShow();

Send command aliShow all and return a hash with C<key> as alias and WWN as value. If you use
option C<-bywwn>, B<key> is WWN and value is alias:

    my %wwn_to_alias = $brcd->aliShow(-bywwn => 1);

By default, option C<-onlywwn> is activated. The command get only WWN mapping. If you use
alias with port number use option C<-byport => 1>. If you have mixed alias, desactivate C<-onlywwn => 0>.

=head2 zoneShow

    my %zone = $brcd->zoneShow();

Return a hash with one key is a zone and value an array of alias member or WWN or ports.

    my %zone = $brcd->zoneShow();

    foreach my $zone (%zone) {
        print "$zone:\n\t";
        print join("; ", keys %{$zone{$zone}} ),"\n";
    }

If you set option C<-bymember=1>, you have a hash with key a member and value an array of
zones where member exists.

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

1.3

=item History

Created 6/27/2005, Modified 3/26/07 18:32:59

=back

=cut
