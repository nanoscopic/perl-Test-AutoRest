# Copyright (C) 2014 David Helkowski
# License CC-BY-SA ( http://creativecommons.org/licenses/by-sa/4.0/ )

package Test::AutoRest;

use LWP::UserAgent;
use HTTP::Request::Common qw/POST GET/;
use HTTP::Cookies;
use XML::Bare qw/forcearray xval/;
use Data::Dumper;
use URI::Encode qw/uri_encode/;
use lib '.';
use Pg::Helper;
use TestFuncs;
use Text::Template qw/fill_in_string/;
use JSON::XS;
use Storable qw/dclone/;
use strict;
use warnings;
use File::Basename;

my $debug = 0;
my $macros = 0;
my %macrohash;
my $csrf = "";

sub new {
    my $class = shift;
    my %params = ( @_ );
    
    my $self = {};
    $self = bless $self, $class;
    
    if( -e 'cookies.txt' ) {
        `rm cookies.txt`;
    }
    my $jar = HTTP::Cookies->new( file => 'cookies.txt', autosave => 1 );
    my $ua = LWP::UserAgent->new();
    my $ua_str = "Mozilla/5.0 (Windows NT 6.1; WOW64; rv:31.0) Gecko/20100101 Firefox/31.0";
    $ua->agent( $ua_str );
    $ua->cookie_jar( $jar );
    
    $self->{'ua'} = $ua;
    
    my $loghandle;
    open( $loghandle, ">>log.xml" ) or die "Cannot open log.xml for writing";
    $self->{'loghandle'} = $loghandle;
    my $files;
    if( $params{'files'} ) {
      $files = $params{'files'};
    }
    if( $params{'file'} ) {
      $files = [ $params{'file'} ];
    }
    $self->{'testfiles'} = $files;
    if( $params{'config'} ) {
      my ( $ob, $xml ) = XML::Bare->simple( file => $params{'config'} );
      $self->apply_config( $xml->{'xml'} );
    }
    $self->{'vars'} = {};
    
    return $self;
}

sub DESTROY {
    my $self = shift;
    close( $self->{'loghandle'} );
}

sub apply_config {
  my ( $self, $config ) = @_;
  
  #print Dumper( $config );
  $self->{'config'} = $config;
  my $httpconf = $config->{'http'};
  if( $httpconf && $httpconf->{'header'} ) {
    my $headers = forcearray( $httpconf->{'header'} );
    my $ua = $self->{'ua'};
    for my $header ( @$headers ) {
      $ua->default_header( $header->{'name'} => $header->{'val'} );
    }
  }
}

sub run {
    my $self = shift;
    my $filesfull = $self->{'testfiles'};
    for my $filefull ( @$filesfull ) {
      my ( $file, $path, $ext ) = fileparse( $filefull );
      my $tests = $self->load_tests( $filefull );
      $self->run_tests( $tests, $path );
    }
}

sub load_tests {
    my ( $self, $file ) = @_;
    my ( $ob, $xml ) = XML::Bare->new( file => $file );
    $xml = $xml->{'xml'};
    
    # We cannot simplify here, because that would strip _pos from the nodes, and cause unmix below to fail
    #$xml = XML::Bare::Object::simplify( $xml->{'xml'} );
    
    my $tests = $xml;
    
    my $config = $xml->{'config'};
    if( $config ) {
        $config = XML::Bare::Object::simplify( $config );
        $self->apply_config( $config );
        delete $xml->{'config'};
    }
    
    if( $tests->{'macro'} ) {
        #$macros = XML::Bare::Object::simplify( $xml->{'macro'} );
        $macros = $tests->{'macro'};
        $macros = forcearray( $macros );
        
        for my $macro ( @$macros ) {
            my $name = $macro->{'name'}{'value'};
            #print "Storing macro $name\n";
            $macrohash{ $name } = $macro;
        }
        delete $tests->{'macro'};
    }
    
    #my $tests = forcearray( $xml->{'test'} );
    #print Dumper( $xml );
    $tests = unmix( $tests );
    #print Dumper( $tests );
    return $tests;
}

sub run_macro {
    my ( $self, $name, $data, $path ) = @_;
    my $macro = $macrohash{ $name };
    my $defines = forcearray( $macro->{'define'} );
    # recursive scan through macro and replace all ## things with their defined values
    
    delete $macro->{'define'};
    my $unmixed = unmix( $macro );
    my $clone = dclone( $unmixed );
    $macro->{'define'} = $defines;
    
    my $hash_for_replace = fill_defines( $defines, $data );
    
    #print Dumper( $clone );
    for my $noden ( @$clone ) {
        my $node = $noden->{'node'};
        deep_replace_in_values( $node, $hash_for_replace );
    }
    #print Dumper( $clone );
    
    print " Is macro\n";
    $self->run_tests( $clone, $path );
    
    1;
}

# Note this does not resolve references to vars. That is done upon execution.
sub fill_defines {
    my ( $defines, $data ) = @_;
    my $hash = {};
    #print "XYZ:".Dumper( $data );
    $defines = XML::Bare::Object::simplify( $defines );
    for my $define ( @$defines ) {
        my $name = $define->{'name'};
        my $var = $define->{'var'};
        $hash->{ $var } = $data->{ $name };
    }
    return $hash;
}

sub deep_replace_in_values {
    my ( $node, $hash ) = @_;
    for my $key ( keys %$node ) {
        my $sv = $node->{ $key };
        my $ref = ref( $sv );
        if( $ref eq 'ARRAY' ) {
            for my $node2 ( @$sv ) {
                deep_replace_in_values( $node2, $hash ); 
            }
        }
        elsif( $ref eq 'HASH' ) {
            deep_replace_in_values( $sv, $hash );
        }
        elsif( $key eq 'value' ) {
            # val is $sv
            if( $sv ) {
                $sv =~ s/#([a-zA-Z0-9_]+)#/hash_replace($1,$hash)/e;
                $node->{ $key } = $sv;
            }
        }
    }
}

sub hash_replace {
    my ( $name, $hash ) = @_;
    #print "Replace $name " . Dumper( $hash );
    my $replace = $hash->{ $name } || '';
    if( ! defined $hash->{ $name } ) {
        print "Cannot find variable: $name\n";
    }
    return $replace;
}

sub new_sql_object {
    my $self = shift;
    my $dbconf = $self->{'config'}{'db'};
    return Pg::Helper->new( $dbconf );
}

sub run_tests {
    my ( $self, $tests, $path ) = @_;
    
    my $success = 1;
    for my $testn ( @$tests ) {
        my $name = $testn->{'name'};
        my $test = XML::Bare::Object::simplify( $testn->{'node'} );
        print "----------------------------------------------------------------------------------------------------\nRunning $name:";
        
        my %builtin = (
            store => \&x_store,
            db_query => \&x_query,
            query => \&x_query,
            db_delete => \&x_delete,
            db_check_exists => \&x_check_exists,
            include => \&x_include
        );
        
        my $result;
        if( $macrohash{ $name } ) {
            $result = $self->run_macro( $name, $test, $path );
        }
        else {
            my $funcref = $builtin{ $name } || \&{ "TestFuncs::x_$name" };
            $result = $funcref->( 
                $test, 
                vars => $self->{'vars'}, 
                config => $self->{'config'},
                system => $self,
                path => $path
            );
        }
        
        if( !$result ) {
            $success = 0;
            print "failed\n";
            last;
        }
        else {
            if( ref( $result ) eq 'HASH' ) {
                if( defined $result->{'ok'} ) {
                    my $ok = $result->{'ok'};
                    if( $ok ) {
                        print "ok\n";
                    }
                    else {
                        print $result->{'error'};
                    }
                }
                if( $result->{'vars'} ) {
                    %{$self->{'vars'}} = ( %{$self->{'vars'}}, %{$result->{'vars'}} );
                }
            }
            else {
                print "ok\n";
            }
        }
    }
    return $success;
}

sub resp_output {
    my $resp = shift;
    my $content = $resp->decoded_content;
    if( !$content ) {
        $content = $resp->content;
    }
    return $content || 0;
}

sub write_url_output {
    my ( $self, $url, $content, $precurse ) = @_;
    my $cachefile = $url;
    
    my $base = $self->{'config'}{'base'};
    $cachefile =~ s|^$base||;
    $cachefile =~ s|/|__|g;
    $cachefile =~ s/[^A-Za-z0-9_]/_/g;
    if( $precurse ) { $cachefile = $precurse.$cachefile; }
    open( C, ">:encoding(UTF-8)", "cache/$cachefile" );
    print C $content;
    close( C );
    return $cachefile;
}

sub geturl {
    my $self = shift;
    #my $get = shift;
    my $url = shift;
    my %ops = ( @_ );
    my $resp;
    my $ua = $self->{'ua'};
    
    my $paramstr = "";
    if( $ops{'params'} ) {
        $paramstr = param_hash_to_str( $ops{'params'} );
    }
    if( $ops{'fixed_params'} ) {
        my $fixed = param_array_to_str( $ops{'fixed_params'} );
        if( $paramstr ) {
            $paramstr = "$fixed&$paramstr";
        }
        else {
            $paramstr = $fixed;
        }
    }
    if( $paramstr ) {
        $url = "$url?$paramstr";
    }
    
    #my $params = {};
    
    my $req = GET $url; #, $parms;
    my $inheaders = $ops{'headers'};
    $req->header( "X-CSRFToken" => $csrf );
    if( $ops{'range'} ) {
        my $range = $ops{'range'};
        my $req = HTTP::Request->new( GET => $url );
        if( $range ) {
            $req->header( "Range" => "items=0-49" );
        }
        $resp = $ua->request( $req );
    }
    if( $inheaders ) {
        for my $hname ( keys %$inheaders ) {
            my $val = $inheaders->{ $hname };
            print "Setting header $hname to $val\n" if( $debug ); 
            $req->header( $hname => $inheaders->{$hname} );
        }
    }
    $resp = $ua->request( $req );
    
    my $code = $resp->code;
    
    my $content = resp_output( $resp );
    
    my $headers = $resp->headers;
    if( $headers ) {
        #print Dumper( $headers );
        my $scs = forcearray( $headers->{'set-cookie'} );
        for my $sc ( @$scs ) {
            if( $sc && $sc =~ m/^csrftoken=([a-zA-Z0-9]+);/ ) {
                $csrf = $1;
                print "Set csrf to $csrf\n" if( $debug );
            }
        }
    }
    
    if( $code == 302 ) {
        my $headers = $resp->headers;
        #print Dumper( $headers );
        $content = "Redirect to $headers->{'location'}\n";
    }
    elsif( $code == 500 ) {
        print "500 error from server\n";
        my $clean = clean_500_error( $content );
        print Dumper( $clean );
    }
    else {
        if( !$resp->is_success ) {
            print "Fail getting $url\n";
            my $cachefile = $self->write_url_output( $url, $content, "fail_" );
            $self->loghash( { lwp => { _type => 'get', _url => $url, _result => 'fail', code => $code, _cache => $cachefile } } );
            return 0;
        }
    }
    my $cachefile = $self->write_url_output( $url, $content );
    $self->loghash( { lwp => { _type => 'get', _url => $url, _result => 'success', _cache => $cachefile } } );
    return $content;
}

sub clean_500_error {
    my $error = shift;
    my @lines = split(/\n/, $error );
    
    my $clean = '';
    for my $line ( @lines ) {
        last if( $line =~ m/^Request Method/ );
        $clean .= "$line\n";
    }
    
    my $trace = '';
    my $intrace = 0;
    for my $line ( @lines ) {
        if( $line =~ m/^Traceback/ ) {
            $intrace = 1;
            next;
        }
        if( $intrace ) {
            if( $line eq '' ) {
                $intrace = 0;
            }
            $clean .= "$line\n";
        }
    }
    return $clean;
}

sub name_value_array_to_hash {
    my ( $self, $arr ) = @_;
    return {} if( !$arr );
    $arr = forcearray( $arr );
    my %params;
    for my $param ( @$arr ) {
        my $name = $param->{'name'};
        my $val = $param->{'val'};
        $params{ $name } = $val;
    }
    return \%params;
}

sub posturl {
    my $self = shift;
    my $url = shift;
    #my $parms = shift;
    my %ops = ( @_ );
    my $parms = $ops{'data'};
    
    my $ua = $self->{'ua'};
    my $resp;
    
    my $paramstr = "";
    if( $ops{'params'} ) {
        $paramstr = param_hash_to_str( $ops{'params'} );
    }
    if( $ops{'fixed_params'} ) {
        my $fixed = param_array_to_str( $ops{'fixed_params'} );
        if( $paramstr ) {
            $paramstr = "$fixed&$paramstr";
        }
        else {
            $paramstr = $fixed;
        }
    }
    if( $paramstr ) {
        $url = "$url?$paramstr";
    }
    
    #if( 0 && $ops{'headers'} ) {
        #my $req = HTTP::Request->new( POST => $url, $parms );
        my $req;
        if( $ops{'rawdata'} ) {
            $req = POST( $url, Content => $ops{'rawdata'}, "Content-Type" => "application/json; charset=UTF-8" );
        }
        else {
            $req = POST $url, $parms;
        }
        my $inheaders = $ops{'headers'};
        $req->header( "X-CSRFToken" => $csrf );
        if( $inheaders ) {
            for my $hname ( keys %$inheaders ) {
                my $val = $inheaders->{ $hname };
                print "Setting header $hname to $val\n" if( $debug ); 
                $req->header( $hname => $inheaders->{$hname} );
            }
        }
        $resp = $ua->request( $req );
    #}
    #else {
    #    $resp  = $ua->post( $url, $parms );
    #}
    
    my $headers = $resp->headers;
    if( $headers ) {
        #print Dumper( $headers );
        my $scs = forcearray( $headers->{'set-cookie'} );
        for my $sc ( @$scs ) {
            if( $sc && $sc =~ m/^csrftoken=([a-zA-Z0-9]+);/ ) {
                $csrf = $1;
                print "Set csrf to $csrf\n" if( $debug );
            }
        }
    }
    
    my $code = $resp->code;
    my $content = resp_output( $resp );
    
    if( $code == 403 ) {
        print "403 error\n";
        print Dumper( $content );
    }
    elsif( $code == 302 ) {
        #print Dumper( $headers );
        $content = "Redirect to $headers->{'location'}\n";
    }
    elsif( $code == 500 ) {
        print "500 error from server\n";
        my $clean = clean_500_error( $content );
        print Dumper( $clean );
        $content = '';
    }
    else {
        if( !$resp->is_success ) {
            print "Fail getting $url; code=$code\n";
            #print Dumper( $content );
            $self->loghash( { lwp => { _type => 'post', _url => $url, _result => 'fail', _code => $code } } );
            return 0;
        }
    }
    my $cachefile = $self->write_url_output( $url, $content, "post_" );
    $self->loghash( { lwp => { _type => 'post', _url => $url, _result => 'success', _cache => $cachefile } } );
    return $content;
}

sub loghash {
    my ( $self, $hash ) = @_;
    complicate( $hash );
    my $xml = XML::Bare::Object::xml( 0, $hash );
    my $handle = $self->{'loghandle'};
    print $handle $xml;
}

sub fill_value {
    my ( $self, $tpl ) = @_;
    if( !$tpl ) { return $tpl; }
    return fill_in_string( $tpl, HASH => $self->{'vars'} );
}

sub fill_values_in_hash {
    my ( $self, $ob ) = @_;
    my $ref = ref( $ob );
    my $arr;
    if   ( $ref eq 'ARRAY' ) { $arr = $ob;     }
    elsif( $ref eq 'HASH'  ) { $arr = [ $ob ]; }
    else                     { die "error";    }
    
    for my $hash ( @$arr ) {
        for my $key ( keys %$hash ) {
            my $val = $hash->{ $key };
            my $ref1 = ref( $val );
            if( !$ref1 ) { $hash->{ $key } = $self->fill_value( $val ); }
        }
    }
}

sub param_hash_to_str {
    my $hash = shift;
    my @parts;
    for my $key ( sort keys %$hash ) {
        my $val = $hash->{ $key };
        push( @parts, "$key=$val" );
    }
    return join( '&', @parts );
}

sub param_array_to_str {
    my $array = shift;
    return join( '&', @$array );
}

# The following two functions are from as of yet unreleased XML::Bare version 0.54
sub complicate {
    my $node = shift;
    my $ref = ref( $node );
    if( $ref eq 'HASH' )  {
        for my $key ( keys %$node ) {
            my $replace = complicate( $node->{ $key } );
            #if( $key =~ m/^$att_prefix(.+)/ ) {
            if( $key =~ m/^\_(.+)/ ) {
                my $newkey = $1;
                delete $node->{ $key };
                $replace->{'_att'} = 1;
                $node->{ $newkey } = $replace;
            }
            else {
                $node->{ $key } = $replace if( $replace );
            }
        }
        return 0;
    }
    
    if( $ref eq 'ARRAY' ) {
        my $len = scalar @$node;
        for( my $i=0;$i<$len;$i++ ) {
            my $replace = complicate( $node->[ $i ] );
            $node->[ $i ] = $replace if( $replace );
        }
        return 0;
    }
    
    return { value => $node };
}

# This named is based on the fact that different nodes in a row can be thought of as "mixed" xml
# The parser doesn't retain mixed order, so it sort of "mixes" the ordered xml nodes
# This function gives you a array of the nodes restored to their original order, "unmixing" them.
# A clearer name for this would be "mixed_hash_to_ordered_nodes". That's a lot longer and more boring.
sub unmix {
    my $hash = shift;
    
    my @arr;
    for my $key ( keys %$hash ) {
        next if( $key =~ m/^_/ || $key =~ m/(value|name|comment)/ );
        my $ob = $hash->{ $key };
        if( ref( $ob ) eq 'ARRAY' ) {
            for my $node ( @$ob ) {
                push( @arr, { name => $key, node => $node } );
            }
        }
        else {
            push( @arr, { name => $key, node => $ob } );
        }
    }
    #print Dumper( \@arr );
    my @res = sort { $a->{'node'}{'_pos'} <=> $b->{'node'}{'_pos'} } @arr;
    return \@res;
}

sub x_include {
  my $test = shift;  my %ops = ( @_ );
  my $system = $ops{'system'}; # config and vars also available
  my $path = $ops{'path'};
  
  my $filerel = $test->{'file'};
  my $filefull = "$path/$filerel";
  if( ! -e $filefull ) {
    print "Cannot include file '$filefull'\n";
    return 0;
  }
  
  my $tests = $system->load_tests( $filefull );
  my ( $file, $newpath, $ext ) = fileparse( $filefull );
  my $result = $system->run_tests( $tests, $newpath );
  return $result;
}

# Shift around stored values
sub x_store {
    my $test = shift; my %ops = ( @_ );
    my $vars = $ops{'vars'};
    #print Dumper( $vars );
    
    my $to = $test->{'to'};
        
    if( defined $test->{'val'} || !$test->{'from'} ) {
        my $val = $test->{'val'};
        $val = $ops{'system'}->fill_value( $val );
        $vars->{ $to } = $val;# we should evaluate this in text::template
    }
    else {
        my $from = $test->{'from'};
        $vars->{ $to } = $vars->{ $from };
    }
    return 1;
}

#<query table="location_tree_node_group">
#                <where description="{{}}All Dealers" organization_id="1" />
#                <fetch col="id" as="dealer_group"/>
#            </query>
sub x_query {
    my $test = shift; my %ops = ( @_ );
    #my $vars = $ops{'vars'};
    my $sys = $ops{'system'};
    
    my $table = $test->{'table'};
    my $fetch = forcearray( $test->{'fetch'} );
    
    my $psql = $sys->new_sql_object();
    
    my $where = dclone( $test->{'where'} );
    $ops{'system'}->fill_values_in_hash( $where );
    
    $fetch = dclone( $fetch );
    $ops{'system'}->fill_values_in_hash( $fetch );
    
    my $fetcharr = [];
    for my $one ( @$fetch ) {
        my $col = $one->{'col'};
        push( @$fetcharr, $col );
    }
    
    for my $key ( keys %$where ) {
        my $val = $where->{ $key };
        if( $val eq 'null' ) {
            $where->{ $key } = { special => 'null' };
        }
    }
    
    my $data = $psql->query( $test->{'table'}, $fetcharr, $where, limit => 1 );
    
    if( $data ) {
        my $vars = {};
        for my $one ( @$fetch ) {
            my $col = $one->{'col'};
            my $val = $data->{ $col };
            my $as = $one->{'as'};
            $vars->{ $as } = $val;
        }
        
        return { ok => 1, vars => $vars };
    }
    else {
        return 0;
    }
}

sub x_delete {
    my $test = shift; my %ops = ( @_ );
    my $sys = $ops{'system'};
    
    my $psql = $sys->new_sql_object();
    my $where = dclone( $test->{'where'} );
    $sys->fill_values_in_hash( $where );
    my $log = $psql->delete_cascade( $test->{'table'}, %$where );
    print join( "\n", @$log ), "\n";
    return 1;
}

# Check if a specific item exists; either via resource or via db
sub x_check_exists {
    my $test = shift; my %ops = ( @_ );
    my $sys = $ops{'system'};
    
    my $psql = $sys->new_sql_object();
    my $where = dclone( $test->{'where'} );
    $ops{'system'}->fill_values_in_hash( $where );
    my $cnt = $psql->check_exists( $test->{'table'}, %$where );
    print "Count: $cnt\n";
    return $cnt;
}

sub json_xml_to_text_double {
    my ( $self, $node ) = @_;
    
    #my %ops = ( @_ );
    #my $double_encode = $ops->{'double_encode'} || 0;
    
    $node = dclone( $node );
    
    my $coder = JSON::XS->new->ascii->allow_nonref;
    my $newhash = {};
    for my $key ( keys %$node ) {
        my $ob = $node->{ $key };
        if( ref( $ob ) eq 'HASH' ) {
            my $type = $ob->{'type'};
            if( $type eq 'num' ) {
                $ob = $ob->{'value'} * 1;
            }
            if( $type eq 'bool' ) {
                $ob = $ob->{'value'} ? $Types::Serialisier::true : $Types::Serialiser::false;
            }
            if( $type eq 'array' ) {
                if( $ob->{'value'} ) {
                    $ob = [ $ob->{'value'} ];
                }
                else {
                    $ob = [];
                }
            }
        }
        
        $newhash->{ $key } = $coder->encode( $ob );
    }
    my $coder2 = JSON::XS->new->ascii->pretty->allow_nonref;
    #print Dumper( $newhash );
    #$newhash = dclone( $newhash );
    $self->fill_values_in_hash( $newhash );
    
    my $json = $coder2->encode( $newhash );
    print "Json:\n" . Dumper( $json );
    return $json;
}

sub json_xml_to_text {
    my ( $self, $node ) = @_;
    
    #my %ops = ( @_ );
    #my $double_encode = $ops->{'double_encode'} || 0;
    
    $node = dclone( $node );
    
    my $newhash = {};
    for my $key ( keys %$node ) {
        my $ob = $node->{ $key };
        if( ref( $ob ) eq 'HASH' ) {
            my $type = $ob->{'type'};
            if( $type eq 'num' ) {
                $ob = $ob->{'value'} * 1;
            }
            if( $type eq 'bool' ) {
                $ob = $ob->{'value'} ? $Types::Serialisier::true : $Types::Serialiser::false;
            }
            if( $type eq 'array' ) {
                if( $ob->{'value'} ) {
                    $ob = [ $ob->{'value'} ];
                }
                else {
                    $ob = [];
                }
            }
        }
        $newhash->{ $key } = $ob;
    }
    print Dumper( $newhash );
    #$newhash = dclone( $newhash );
    $self->fill_values_in_hash( $newhash );
    my $coder = JSON::XS->new->ascii->pretty;
    my $json = $coder->encode( $newhash );
    print "Json:\n" . Dumper( $json );
    return $json;
}

1;