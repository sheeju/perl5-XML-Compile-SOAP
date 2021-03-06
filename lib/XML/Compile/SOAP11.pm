# This code is part of distribution XML-Compile-SOAP.  Meta-POD processed
# with OODoc into POD and HTML manual-pages.  See README.md
# Copyright Mark Overmeer.  Licensed under the same terms as Perl itself.

package XML::Compile::SOAP11;
use base 'XML::Compile::SOAP';

use warnings;
use strict;

use Log::Report              'xml-compile-soap';

use XML::Compile::SOAP::Util qw/:soap11/;
use XML::Compile::Util       qw/pack_type unpack_type type_of_node/;

# publish interface to WSDL
use XML::Compile::SOAP11::Operation ();

__PACKAGE__->register
  ( WSDL11SOAP
  , &SOAP11ENV => 'XML::Compile::SOAP11::Operation'
  );

=chapter NAME
XML::Compile::SOAP11 - SOAP 1.1 protocol

=chapter SYNOPSIS
 # use either XML::Compile::SOAP11::Client or ::Server
 # See XML::Compile::SOAP for global usage examples.

=chapter DESCRIPTION
This module handles the SOAP protocol version 1.1.
See F<http://www.w3.org/TR/2000/NOTE-SOAP-20000508/>).
The implementation tries to behave like described in
F<http://www.ws-i.org/Profiles/BasicProfile-1.0.html>

Two extensions are made: the SOAP11 client
M<XML::Compile::SOAP11::Client>.
and server in M<XML::Compile::SOAP11::Server>.

=chapter METHODS

=section Constructors

=method new %options
To simplify the URIs of the actors, as specified with the C<destination>
option, you may use the STRING C<NEXT>.  It will be replaced by the
right URI.

=default media_type C<text/xml>
=cut

sub new($@)
{   my $class = shift;
    $class ne __PACKAGE__
        or error __x"only instantiate a SOAP11::Client or ::Server";
    $class->SUPER::new(@_);
}

sub init($)
{   my ($self, $args) = @_;
    $args->{media_type} ||= 'text/xml';
    $self->SUPER::init($args);
    $self->_initSOAP11($self->schemas);
}

sub _initSOAP11($)
{   my ($self, $schemas) = @_;

    return $self
        if $schemas->{did_init_SOAP11}++;   # ugly

    $self->_initSOAP($schemas);

    (my $xsddir = __FILE__) =~ s!\.pm$!/xsd!;
    $schemas->addPrefixes('SOAP-ENV' => SOAP11ENV);
    $schemas->importDefinitions("$xsddir/soap-envelope.xsd");

    $self->_initRpcEnc11($schemas, $xsddir)
        if $self->can('_initRpcEnc11');

    $self;
}

sub _initWSDL11($)
{   my ($class, $wsdl) = @_;

    return $class
        if $wsdl->{did_init_SOAP11_WSDL}++;   # ugly

    trace "initialize SOAP11 for WSDL11";

    (my $xsddir = __FILE__) =~ s!SOAP11\.pm$!WSDL11/xsd!;
    $wsdl->importDefinitions("$xsddir/wsdl-soap.xsd");
    $wsdl->addPrefixes(soap => WSDL11SOAP);

    $wsdl->declare(READER =>
      [ "soap:address", "soap:operation", "soap:binding"
      , "soap:body",    "soap:header",    "soap:fault" ]);
    $class;
}

sub version    { 'SOAP11' }
sub envelopeNS { SOAP11ENV }
sub envType($) { pack_type SOAP11ENV, $_[1] }

#-----------------------------------

=section Single message

=method compileMessage <'SENDER'|'RECEIVER'>, %options

=option  headerfault ENTRIES
=default headerfault []
ARRAY of simple name with element references, for all expected
faults.  There can be unexpected faults, which will not get
decoded automatically.

=cut

sub compileMessage($$)
{   my ($self, $direction, %args) = @_;
    $args{style}    ||= 'document';

    if(ref $args{body} eq 'ARRAY')
    {   my @h = @{$args{body}};
        my @parts;
        push @parts, +{name => shift @h, element => shift @h} while @h;
        $args{body} = +{use => 'literal', parts => \@parts};
    }

    if(ref $args{header} eq 'ARRAY')
    {   my @h = @{$args{header}};
        my @o;
        while(@h)
        {  my $part = +{name => shift @h, element => shift @h};
           push @o, +{use => 'literal', parts => [$part]};
        }
        $args{header} = \@o;
    }

    my $f = $args{faults};
    if(ref $f eq 'ARRAY')
    {   $args{faults} = +{};
        my @f = @$f;
        while(@f)
        {   my $name = shift @f;
            my $part = +{name => $name, element => shift @f};
            $args{faults}{$name} = +{use => 'literal', part => $part};
        }
    }

    $self->SUPER::compileMessage($direction, %args);
}

#------------------------------------------------
# Sender

sub _sender(@)
{   my ($self, %args) = @_;

    ### merge info into headers
    # do not destroy original of args
    my %destination = @{$args{destination} || []};

    my $understand  = $args{mustUnderstand};
    my %understand  = map +($_ => 1),
        ref $understand eq 'ARRAY' ? @$understand
      : defined $understand ? $understand : ();

    foreach my $h ( @{$args{header} || []} )
    {   my $part  = $h->{parts}[0];
        my $label = $part->{name};
        $part->{mustUnderstand} ||= delete $understand{$label};
        $part->{destination}    ||= delete $destination{$label};
    }

    if(keys %understand)
    {   error __x"mustUnderstand for unknown header {headers}"
          , headers => [keys %understand];
    }

    if(keys %destination)
    {   error __x"destination for unknown header {headers}"
          , headers => [keys %destination];
    }

    # faults are always possible
    my @bparts  = @{$args{body}{parts} || []};
    my $w = $self->schemas->writer('SOAP-ENV:Fault'
      , include_namespaces => sub {$_[0] ne SOAP11ENV && $_[2]}
      );
    push @bparts,
      { name    => 'Fault'
      , element => pack_type(SOAP11ENV, 'Fault')
      , writer  => $w
      };
    local $args{body}{parts} = \@bparts;

    $self->SUPER::_sender(%args);
}

sub _writer_header($)
{   my ($self, $args) = @_;
    my ($rules, $hlabels) = $self->SUPER::_writer_header($args);

    my $header = $args->{header};
    my @rules;
    foreach my $h (@{$header || []})
    {   my $part  = $h->{parts}[0];
        my $label = $part->{name};
        $label eq shift @$rules or panic;
        my $code  = shift @$rules;

        # fixed in SOAP12, but SOAP11 only understands numeric boolean values
        my $understand
           = $part->{mustUnderstand}         ? '1'
           : defined $part->{mustUnderstand} ? '0'    # explicit 0
           :                                   undef;

        my $actor = $part->{destination};
        if(ref $actor eq 'ARRAY')
        {   $actor = join ' ', map $self->roleURI($_), @$actor }
        elsif(defined $actor)
        {   $actor =~ s/\b(\S+)\b/$self->roleURI($1)/ge }

        my $envpref = $self->schemas->prefixFor(SOAP11ENV);
        my $wcode = $understand || $actor
         ? sub
           { my ($doc, $v) = @_;
             my $xml = $code->($doc, $v);
             $xml->setAttribute("$envpref:mustUnderstand" => '1')
                 if defined $understand;
             $xml->setAttribute("$envpref:actor" => $actor)
                 if $actor;
             $xml;
           }
         : $code;

        push @rules, $label => $wcode;
    }

    (\@rules, $hlabels);
}

sub _writer_faults($)
{   my ($self, $args) = @_;
    my $faults = $args->{faults} ||= {};

    my (@rules, @flabels);

    # Include all namespaces in Fault, because we have no idea which namespace
    # is used for the error code. It automatically defines everything
    # which may be used in the detail block.
    my $wrfault = $self->_writer('SOAP-ENV:Fault'
      , include_namespaces => sub {$_[0] ne SOAP11ENV});

    while(my ($name, $fault) = each %$faults)
    {   my $part = $fault->{part};
        my ($elem, $details) = $self->_write_one_fault($args, $part);

        my $code = sub
          { my ($doc, $data)  = (shift, shift);
            my %copy = %$data;
            $copy{faultactor} = $self->roleURI($copy{faultactor});
            my $det  = delete $copy{detail};
            my @det  = !defined $det ? () : ref $det eq 'ARRAY' ? @$det : $det;
            $copy{detail}{$elem} = [ map $details->($doc, $_), @det ];
            $wrfault->($doc, \%copy);
          };

        push @rules, $name => $code;
        push @flabels, $name;
    }

    (\@rules, \@flabels);
}

sub _write_one_fault($$)
{   my ($self, $args, $part) = @_;

    # spec says: details ALWAYS namespace qualified!
    if(my $elem = $part->{element})
    {   my $writer = $self->{writer} ||=
            $self->_writer($elem
              , include_namespaces => sub {$_[0] ne SOAP11ENV && $_[2]});
        return ($elem, $writer);
    }

    if(my $type = $part->{type})
    {   my $elem   = $part->{name};
        my $writer = $part->{writer} ||= $self->schemas->compileType
          ( WRITER  => $part->{type}, %$args
          , element => $part->{name}
          , include_namespaces => sub {$_[0] ne SOAP11ENV && $_[2]}
          );
       return ($elem, $writer);
    }

    error __x"fault part {name} has neither `element' nor `type' specified"
       , name => $part->{name};
}

##########
# Receiver

sub _reader_fault_reader()
{   my $self = shift;

    # Nasty, nasty: the spec requires name-space qualified on details,
    # even when the schema does not specify that.
    my $schemas = $self->schemas;
    my $x = sub {
       my ($xml, $reader, $path, $tag, $r) = @_;
       my @childs = grep $_->isa('XML::LibXML::Element'), $xml->childNodes;
       @childs or return ();

       my %h;
       foreach my $node (@childs)
       {   my $type  = type_of_node($node);
           push @{$h{_ELEMENT_ORDER}}, $type;
           my $dec   = try { $schemas->reader($type)->($node) };
           $h{$type} = $dec // $node;
       }
       ($tag => \%h);
    };

    [ Fault => pack_type(SOAP11ENV, 'Fault')
    , $self->schemas->reader('SOAP-ENV:Fault'
        , hooks => { type => 'SOAP-ENV:detail', replace => $x } )
    ];
}

sub _reader_faults($$)
{   my ($self, $args, $faults) = @_;

    my %names;
    while(my ($name, $def) = each %$faults)
    {   $names{$def->{part}{element} || $name} = $name;
    }

    sub
    {   my $data   = shift;
        my $faults  = $data->{Fault}    or return;

        my ($code_ns, $code_err) = unpack_type $faults->{faultcode};
        my ($err, @sub_err) = split /\./, $code_err;
        $err = 'Receiver' if $err eq 'Server';
        $err = 'Sender'   if $err eq 'Client';

        my %nice =
          ( code   => $faults->{faultcode}
          , class  => [ $code_ns, $err, @sub_err ]
          , reason => $faults->{faultstring}
          );

        $nice{role} = $self->roleAbbreviation($faults->{faultactor})
            if $faults->{faultactor};

        my $details = $faults->{detail};
        my $dettype = $details ? delete $details->{_ELEMENT_ORDER} : undef;

        my $name;
        if(!$details) { $name = 'error' }
        elsif(@$dettype && $names{$dettype->[0]})
        {   # fault named in WSDL
            $name = $names{$dettype->[0]};
            if(keys %$details==1)
            {   my (undef, $v) = %$details;
                if(ref $v eq 'HASH') { @nice{keys %$v} = values %$v }
                else { $nice{details} = $v }
            }
        }
        elsif(keys %$details==1)
        {   # simple generic fault, not in WSDL. Maybe internal server error
            ($name) = keys %$details;
            my $v = $details->{$name};
            my @v = ref $v eq 'ARRAY' ? @$v : $v;
            my @r = map { UNIVERSAL::isa($_, 'XML::LibXML::Node')
                          ? $_->textContent : $_} @v;
            $nice{$name} = @r==1 ? $r[0] : \@r;
        }
        else
        {   # unknown complex generic error
            $name = 'generic';
        }

        $data->{$name}   = \%nice;
        $faults->{_NAME} = $name;
        $data;
    };
}

sub replyMustUnderstandFault($)
{   my ($self, $type) = @_;

   +{ Fault =>
      { faultcode   => pack_type(SOAP11ENV, 'MustUnderstand')
      , faultstring => "SOAP mustUnderstand $type"
      }
    };
}

sub roleURI($) { $_[1] && $_[1] eq 'NEXT' ? SOAP11NEXT : $_[1] }
sub roleAbbreviation($) { $_[1] && $_[1] eq SOAP11NEXT ? 'NEXT' : $_[1] }

#-------------------------------------
# docs of ::SOAP11::Encoding inserted here
=subsection Encoding
=subsection Decoding
=cut

#-------------------------------------

=chapter DETAILS

=section Header and Body entries

You only call M<compileMessage()> explicitly if you do not have a WSDL
file which contains this information. In the unlucky situation, you
have to dig out the defined types by hand.

But even with a WSDL, there are still a few problems you may encounter.
For instance, the WSDL will not contain C<mustUnderstand> and C<actor>
header routing information.  You can add these to the compileClient call

  my $call = $wsdl->compileClient
    ( 'MyCall'
    , mustUnderstand => 'h1'
    , destination    => [ h1 => 'NEXT' ]
    );

=subsection Simplest form

In the simplest form, the C<header> and C<body> refer (optionally) to a
list of PAIRS, each containing a free to choose unique label and the
type of the element.  The unique label will be used in the Perl HASH
which represents the message.

 my $h1el = pack_type $myns, $some_local;
 my $b1el = 'myprefix:$other_local';

 my $encode_query = $client->compileMessage
   ( 'SENDER'
   , header   => [ h1 => $h1el ]
   , body     => [ b1 => $b1el ]
   , mustUnderstand => 'h1'
   , destination    => [ h1 => 'NEXT' ]
   );

=subsection Most powerful form

When the simple form is too simple, you can use a HASH for the header,
body or both.  The HASH structure is much like the WSDL structure.
For example:

 my $encode_query = $client->compileMessage
   ( 'SENDER'
   , header   =>
      { use   => 'literal'
      , parts => [ { name => 'h1', element => $h1el
                   , mustUnderstand => 1, destination => 'NEXT'
                   } ]
      }
   , body     => [ b1 => $b1el ]
   );

So, the header now is one HASH, which tells us that we have a literal
definition (this is the default).  The optional parts for the header is
an ARRAY of HASHes, each describing one part.  As you can see, the
mustUnderstand and destination fields are more convenient (although
the other syntax will work as well).

If you feel the need to control the compilation of the various parts,
with hooks or options (see M<XML::Compile::Schema::compile()>), then have
a look at M<XML::Compile::Cache::declare()>.  Declare how to handle the
various types before you call M<compileMessage()>.

=section Receiving faults in SOAP1.1

When faults are received, they will be returned with the C<Fault> key
in the data structure.  So:

  my $answer = $call->($question);
  if($answer->{Fault}) { ... }

As extra service, for each of the fault types, as defined with
M<compileMessage(faults)>, a decoded structure is included.  The name
of that structure can be found like this:

  if(my $faults = $answer->{Fault})
  {   my $name    = $faults->{_NAME};
      my $decoded = $answer->{$name};
      ...
  }

The untranslated C<$faults> HASH looks like this:

 Fault =>
   { faultcode => '{http://schemas.xmlsoap.org/soap/envelope/}Server.first'
   , faultstring => 'my mistake'
   , faultactor => 'http://schemas.xmlsoap.org/soap/actor/next'
   , detail => { '{http://test-types}fault_one' => [ XMLNODES ] }
   , _NAME => 'fault1'
   }

The C<_NAME> originates from the M<compileMessage(faults)> option:

   $soap->compileMessage('RECEIVER', ...
     , faults => [ fault1 => '{http://test-types}fault_one' ] );

Now, automatically the answer will contain the decoded fault
structure as well:

  fault1 =>
    { code => '{http://schemas.xmlsoap.org/soap/envelope/}Server.first'
    , class  => [ 'http://schemas.xmlsoap.org/soap/envelope/'
         , 'Receiver', 'first' ]
    , reason => 'my mistake',
    , role   => 'NEXT'
    , detail => { help => 'please ignore' }
    }

The C<detail> is the decoding of the XMLNODES, which are defined to
be of type C<< {http://test-types}fault_one >>.

The C<class> is an unpacked version of the code.  SOAP1.2 is using the
(better) terms C<Sender> and C<Receiver>.

C<role> is constructed by decoding the C<faultactor> using
M<roleAbbreviation()>.  The names are closer to the SOAP1.2 specification.

If the received fault is of an unpredicted type, then the client tries
to DWIM. in the worst case, C<detail> will list the unparsed XMLNODEs.
When the M<XML::Compile::SOAP::Daemon> server has produced the error,
the content of the reply will typically be

 { Fault =>        # SOAP version specific
    { _NAME => 'error'
    , #...more...
    }
 , error =>        # less SOAP version specific, readable
    { role    => 'NEXT'
    , reason  => 'procedure xyz for SOAP11 produced an invalid response'
    , error   => 'some explanation'
    , code    =>
        '{http://schemas.xmlsoap.org/soap/envelope/}Server.invalidResponse'
    , class   => [ SOAP11ENV, 'Receiver', 'invalidResponse' ],
    }
  }

Hence, a typical client routine could contain

  my ($answer, $trace) = $call->(message => $message);
  if(my $f = $answer->{Fault})
  {   if($f->{_NAME} eq 'error')
      {   # server implementation error
          die "SERVER ERROR:\n$answer->{error}{error}\n";
      }
      else
      {   # the fault is described in the WSDL, handle it!
          warn "FAULT:\n",Dumper $answer->{$f->{_NAME}};
      }
  }
  else
  {   # correct answer
      print Dumper $answer;
  }

Or

  my ($answer, $trace) = $call->(message => $message);
  $answer or die $trace->error;
=cut

1;
