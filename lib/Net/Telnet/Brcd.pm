package Net::Telnet::Brcd;

# @(#)Brcd.pm	1.10

=pod

=head1 NAME

Net::Telnet::Brcd - Module d'interrogation des switchs Brocade

=head1 SYNOPSIS

    use Net::Telnet::Brcd;

    my $sw = new Net::Telnet::Brcd;

    $sw->connect($sw_name,$user,$pass) or die "\n";

    %wwn_port = $sw->switchShow(-bywwn=>1);
    my @lines = $sw->cmd("configShow");

=head1 DESCRIPTION

Biblioth�que d'interrogation via Telnet de switch Brocade.

=cut

use Net::Telnet;
use Carp;
use strict;
use constant DEBUG => 0;

require Exporter;

# Variables de gestion du package
our %EXPORT_TAGS = ( 'all' => [ qw() ] );
our @EXPORT_OK   = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT      = qw();
our $VERSION     = 0.01;
our @ISA         = qw(Exporter);

# Variables priv�es
my $_brcd_prompt     = '\w+:\w+>\s+';
my $_brcd_continue   = 'Type <CR> to continue, Q<CR> to stop:';
my $_brcd_prompt_re  = "/(?:${_brcd_prompt}|${_brcd_continue})/";
my $_brcd_wwn_re     = join(":",("[0-9A-Za-z][0-9A-Za-z]") x 8);
my $_brcd_port_id    = qr/\d+,\d+/;
my $_brcd_timeout    = 20; # secondes

=head2 new

    my $brcd = new Net::Telnet::Brcd;

Initialise un objet Brocade. A faire avant toute commande.

=cut

sub new {
    my ($class)=shift;

    $class = ref($class) || $class;

    my $self={};

    $self->{TELNET} = new Net::Telnet (Timeout => ${_brcd_timeout},
                                       Prompt  => "/${_brcd_prompt}/",
                                       );

    $self->{TELNET}->errmode("return");

    bless $self, $class;
    return $self;
}

=head2 connect

    $brcd->connect($switch,$user,$pass);

Se connecte � un switch Brocade par la session Telnet. Renvoie undef en cas d'erreur.
A faire avant toute commande sur un switch.

=cut

sub connect {
    my ($self,$switch,$user,$pass)=@_;

    $user ||= $ENV{BRCD_USER} || "admin";
    $pass ||= $ENV{BRCD_PASS};

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

=head2 cmd

    my @results=$brcd->cmd("configShow");

Envoie une commande au switch et r�cup�re les lignes de sorties sans les \r\n.
Chaque ligne de sortie est une ligne de tableau.

Dans le cas ou la ligne de commande est envoy�e sous forme de tableau:

    my @results=$brcd->cmd("aliAdd","toto",":00:00:0:5:4:54:4:5");

La commande est lanc�e et g�n�r�e de la fa�on suivante:

    aliAdd "toto", ":00:00:0:5:4:54:4:5"

=cut

sub cmd {
    my ($self,$cmd,@cmd)=@_;
    
    if (@cmd) {
        $cmd.=" \"".join("\", \"",@cmd)."\"";
    }
    
    warn "Execute: $cmd\n";

    unless ($self->{TELNET}->print($cmd)) {
        carp __PACKAGE__,": Cannot send cmd '$cmd': $!\n";
        return;
    }
    # Lecture en passant les continue
    @cmd = ();
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

=head2 aliShow

    my %alias_to_wwn = $brcd->aliShow();

Passe la commande aliShow et g�n�re un haschage contenant comme cl� les alias
et comme valeur les WWN.

Si l'option -bywwn est activ�e:

    my %wwn_to_alias = $brcd->aliShow(-bywwn => 1);

c'est l'inverse qui est renvoy�e.

Par  d�faut, l'option -onlywwn est activ�e. Ceci indique que les ports zon�s
par port ne sont pas renvoy�s. Dans l'autre cas, ils le sont.

Avec l'option -byport, seuls les alias contenant des ports sont renvoy�s.

=cut

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
    foreach ($self->cmd("aliShow \"*\"")) {
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

    return ($args{'-bywwn'})  ? (%{$fab->{WWN}})    :
           ($args{'-byport'}) ? (%{$fab->{PORTID}}) :                  
                                (%{$fab->{ALIAS}});
}

=head2 zoneShow

    my %zone = $brcd->zoneShow();

La commande renvoie gr�ce � la commande zoneShow un haschage contenant les
membres de chaque zone. Chaque cl� de haschage correspond � une zone. Une cl�
contient chaque membre sous forme de tableau associatif. Exemple:

    my %zone = $brcd->zoneShow();

    foreach my $zone (%zone) {
        print "$zone:\n\t";
        print join("; ", keys %{$zone{$zone}} ),"\n";
    }

Si l'option -bymember est utilis�, c'est l'inverse qui est pr�sent�. C'est � dire
� quelle zone appartient un membre. La m�thode d'acc�s est la m�me.

Si cette m�thode d'acc�s n'est pas ais�e, on peut utiliser les fonctions suivantes.

=cut

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

=head2 zoneMember

    my @member = $brcd->zoneMember("z_sctxp004_0");

Renvoie la liste des membres d'une zone. Un membre est un alias
ou un WWN suivant la m�thode utilis�e.

Cette fonction n�cessite d'avoir ex�cut� la commande $brcd->zoneShow pr�c�demment.

=cut

sub zoneMember {
    my ($self,$zone)=@_;

    my $fab_name = $self->{FABRIC};
    my $fab      = $self->{FABRICS}->{$fab_name};

    return unless exists $fab->{ZONE}->{$zone};

    return sort keys %{$fab->{ZONE}->{$zone}};
}

=head2 memberZone

    my @zones = $brcd->memberZone("w_sctxp004_0");

Renvoie la liste des zones auquel appartient un membre. Un membre est un alias
ou un WWN suivant la m�thode utilis�e.

Cette fonction n�cessite d'avoir ex�cut� la commande $brcd->zoneShow pr�c�demment.

=cut

sub memberZone {
    my ($self,$member)=@_;

    my $fab_name = $self->{FABRIC};
    my $fab      = $self->{FABRICS}->{$fab_name};

    return unless exists $fab->{MEMBER}->{$member};

    return sort keys %{$fab->{MEMBER}->{$member}};
}

=head2 switchShow

    my %port = $brcd->switchShow();

Cette commande passe la commande switchShow sur le switch physique de connexion.
Ceci permet de donner l'�tat de chaque port suivant la structure suivante:

    $port{<port number}->{SPEED}  = <2G|1G|...>
                       ->{STATUS} = <OnLine|NoLight|...>
                       ->{SLOT}   = num�ro de la blade
                       ->{NUMBER} = num�ro du port dans la blade
                       ->{TYPE}   = <E-Port|F-Port|...>
                       ->{WWN}    si connect�

Avec l'option -bywwn, la commande renvoie simplement la liste des WWN et les num�ros
de port associ�s.

    my %wwn_to_port = $brcd->switchShow(-bywwn => 1);

L'optoin -withportname peut �tre activ�e, ceci implique de passer la commande portName 
� chaque port. Le temps de l'ex�cution est fortement augment�.

=cut

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
DEBUG && warn  "SWITCHSHOW   : $_\n";
            if (m/^(\w+):\s+(.+)/) {
                $fab->{$1} = $2;
                next;
            }
            if (m/^(?:port)?\s+(\d+):?\s+(?:(\d+)\s+(\d+)\s*)?id\s+(\w+)\s+(\w+)\s*(.*)/) {
DEBUG && warn  "SWITCHSHOW-RE: #$1# #$2# #$3# #$4# #$5# #$6#\n";
                my $port_number      = $1;
                my $port_info        = $6;
                my $port_slot        = $2;
                my $port_slot_number = $3;

                $fab->{PORT}->{$port_number}->{SPEED}    = $4;
                $fab->{PORT}->{$port_number}->{STATUS}   = $5;
                $fab->{PORT}->{$port_number}->{SLOT}     = $port_slot        if defined $port_slot;
                $fab->{PORT}->{$port_number}->{NUMBER}   = $port_slot_number if defined $port_slot_number;
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

=head2 toSlot

    my ($slot,$slot_number) = $brcd->toSlot(36);
    my $slot_address        = $brcd->toSlot(36);

Cette commande fonctionne que si la commande switchShow a d�j� �t� pass�e. Elle
donne pour un switch type DIRECTOR le slot et le num�ro dans le slot pour un 
num�ro de port donn�. Pour un switch classique, elle ne renvoie rien.

En contexte scalaire, elle renvoie directement slot/slot_number (format de la
commande portShow).

=cut

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

=head2 portShow

    my %port     = $brcd->portShow($port_number);
    my $portname = $brcd->portShow($port_number);

Cette commande fonctionne que si la commande switchShow a d�j� �t� pass�e.

Elle utilise la commande toSlot pour passer la commande portShow automatiquement quelque
soit le type de switch SAN.

En contexte de liste, la commande renvoie un haschage ou la cl�
est le param�tre (portName par exemple) et la valeur la valeur associ�e.

Dans un contexte scalaire, la commande portShow renvoie le portname.

=cut

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

=head2 output

    print $brcd->output();

Retourne la sortie d'une commande pass� par $brcd->cmd("...") sous forme
de cha�ne de caract�re directement imprimable � l'�cran ou dans un fichier.

=cut

sub output {
    my $self=shift;

    return join("\n",@{$self->{OUTPUT}})."\n";
}

=head2 wwn_re

    my $wwn_re = $brcd->wwn_re();

    if (m/($wwn_re)/) {
        ...
    }

Retourne une cha�ne de caract�re correspondant � l'expression r�guli�re de
recherche d'un WWN.

=cut

sub wwn_re {
    return ${_brcd_wwn_re};
}

sub DESTROY {
    my $self=shift;

    $self->{TELNET}->close();
}

=head2 fabricShow

    my %fabric = $brcd->fabricShow();

Retourne un haschage compos� de tous les switchs pr�sents dans une fabric. La valeur contient
le DOMAIN et l'IP et la fabric au sens DNS long du switch en question.

=cut
use Socket;

sub fabricShow {
    my $self=shift;
    my %args=(
          -bydomain        => 0,
          @_
          );
    my (%fabric,%domain);
    
    foreach ($self->cmd("fabricShow")) {
DEBUG && warn "DEBUG:: $_\n";
        if (m/^\s*(\d+):\s+\w+\s+${_brcd_wwn_re}\s+(\d+\.\d+\.\d+\.\d+)\s+\d+\.\d+\.\d+\.\d+\s+>?"([^"]+)/) {
            my ($domain_id, $switch_ip, $switch_name) = ($1, $2, $3);
            $domain{$domain_id}->{NAME}     = $switch_name;
            $domain{$domain_id}->{IP}       = $switch_ip;
            $domain{$domain_id}->{FABRIC}   = gethostbyaddr(inet_aton($switch_ip), AF_INET);
            $fabric{$switch_name}->{DOMAIN} = $domain_id;
            $fabric{$switch_name}->{IP}     = $switch_ip;
            $fabric{$switch_name}->{FABRIC} = $domain{$domain_id}->{FABRIC};
            $fabric{$domain{$domain_id}->{FABRIC}} = $switch_name;
        }
    }
    
    return ($args{-bydomain}) ? (%domain) :
                                (%fabric);
}

=head2 currentFabric

    my $dns_fabric = $brcd->currentFabric();

Retourne le nom DNS de la fabric.

=cut


sub currentFabric {
    my $self = shift;
    
    return $self->{FABRIC};
}

=head2 isWwn

    if ($brcd->isWwn($str)) {
        ...
    }

Teste une chaine et v�rifie que c'est un WWN.

=cut


sub isWwn {
    my $self = shift;    
    my $wwn = shift;
    
    ($wwn =~ m/^${_brcd_wwn_re}/)?(return 1):(return);
    
}

=head2 portAlias

    my ($domain, $port_number) = $brcd->portAlias("199,6");

D�coupe une cha�ne au format zoning par port en domaine et num�ro de port
dans le swtich.

=cut


sub portAlias {
    my $self = shift;
    my $port_alias = shift;
    
    if ($port_alias =~ m/(\d+),(\d+)/){
        return ($1, $2);
    }
    return;
}

1;

=head1 SEE ALSO

Documentation Brocade, Brocade API et Net::Telnet.

=head1 AUTHOR

Laurent Bendavid, E<lt>laurent.bendavid@dassault-aviation.comE<gt>

=head1 COPYRIGHT AND LICENSE
                                                                                
Copyright (C) 2006 by Laurent Bendavid
                                                                                
This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.3 or,
at your option, any later version of Perl 5 you may have available.

=over

=item Version

1.10

=item History

Created 6/27/2005, Modified 9/8/05 16:55:04

=back

=cut
