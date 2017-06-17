#!/usr/bin/perl --
use utf8;
use strict;
use warnings;
use Getopt::Long;
use JSON;
use Encode;
use URI::Escape;
use feature qw( say );
use LWP::UserAgent;

binmode \*STDOUT,":encoding(utf8)";
binmode \*STDERR,":encoding(utf8)";

sub usage{
	my($err) = @_;
	$err and say $err;

	print <<"END";
(to create access_info.json)
usage: $0 -i instance-name -u user-mail-address -p password -c access_info.json
options:
  -i instance          : host name of instance
  -u user-mail-address : user mail address
  -p password          : user password
  -c config_file       : file to save instance-name,client_id,client_secret,access_token
  -v                   : verbose mode.

(to dump follow list)
usage: $0 -t access_info.json
options:
  -c config_file  : file to load instance-name,client_id,client_secret,access_token
  -s stream-type  : comma-separated list of stream type. default is 'public:local'
  -v              : verbose mode.
END
	exit 1;
}

my $verbose=0;
my $opt_instance="";
my $opt_user="";
my $opt_password="";
my $opt_config="";
my $opt_name="DumpFollowList";

GetOptions(
	"verbose:+"  => \$verbose,
	"instance=s" => \$opt_instance, 
	"user=s"   => \$opt_user,  
	"password=s"   => \$opt_password,  
	"config=s"   => \$opt_config,  
	"name=s"   => \$opt_name,  
) or usage "bad options.";

if( not $opt_config ){
	usage();
}

$verbose and warn "verbose=$verbose\n";
$verbose and warn "opt_instance=$opt_instance\n";
$verbose and warn "opt_user=$opt_user\n";
$verbose and warn "opt_config=$opt_config\n";

####################################################
# ユーティリティ

my $UTF8 = Encode::find_encoding( 'utf8');
my $ua = LWP::UserAgent->new;
$ua->timeout(120);
$ua->env_proxy;

sub postApi{
	my($path,$data)=@_;

	my $url = "https://$opt_instance$path";
	warn "POST $url\n";

	my $req = HTTP::Request->new(POST => $url);
	my $bytes = $UTF8->decode($data);
	$req->header('Content-Type','application/x-www-form-urlencoded');
	$req->header('Content-Length',"".length($bytes) );
	$req->content( $bytes);

	my $res = $ua->request( $req );
	$res->is_success or die "Error: ",$res->status_line,"\n";
	$data = eval{ decode_json $res->content };
	$@ and die "could not parse JSON response. $@\n";
	$data or die "missing JSON response.\n";
	return $data;
}



####################################################
# 認証してトークンをファイルに保存

if( $opt_instance and $opt_user and $opt_password ){
	#
	warn "register client '$opt_name' ...\n";
	my $data = "";
	$data .= "client_name=" . uri_escape($opt_name);
	$data .= "&redirect_uris=urn:ietf:wg:oauth:2.0:oob";
	$data .= "&scopes=read";
	my $client_info = postApi( "/api/v1/apps", $data );
	if( not $client_info->{client_id} or not $client_info->{client_secret} ){
		die "could not get client_id, client_secret.\n";
	}

	#
	warn "get access_token...\n";
	$data = "";
	$data .= "client_id=" . $client_info->{client_id};
	$data .= "&client_secret=" . $client_info->{client_secret};
	$data .= "&grant_type=password";
	$data .= "&username=" . uri_escape($opt_user);
	$data .= "&password=" . uri_escape($opt_password);
	my $token_info = postApi( "/oauth/token", $data );
	if( not $token_info->{access_token} ){
		die "could not get access_token.\n";
	}
	
	if( not $opt_config ){
		die "token is NOT saved because configuration file name is not specified.\n";
	}
	
	open(my $fh,">",$opt_config) or die "$opt_config : $!";
	print $fh encode_json { instance=>$opt_instance, client_info=>$client_info, token_info=>$token_info};
	close($fh) or die "$opt_config : $!";
	say "instance and client_id and access_token is saved to $opt_config.";
	exit;
}

####################################################
# 保存したトークンを読み込む

my $config;
{
	my $json;
	{
		open(my $fh,"<",$opt_config) or die "$opt_config : $!";
		local $/ = undef;
		$json = <$fh>;
		close($fh) or die "$opt_config : $!";
	}
	$config = eval{ decode_json $json };
	$@ and die "could not parse JSON data in $opt_config. $@\n";
	$config or die "missing config data.\n";
}

sub getApi{
	my($path)=@_;

	my $url = "https://$config->{instance}$path";
	warn "GET $url\n";

	my $res = $ua->get( $url
		,Authorization => "Bearer ".$config->{token_info}{access_token} 
	);
	if( not $res->is_success ){
		die "Error: ",$res->status_line,"\n";
	}
	my $data = eval{ decode_json $res->content };
	$@ and die "could not parse JSON response. $@\n";
	$data or die "missing JSON response.\n";
	return ($data,$res);
}

####################################################
# 自分の情報

my($me)= getApi('/api/v1/accounts/verify_credentials');
if( not $me or not $me->{id} ){
	die "verify_credentials failed.\n";
}

####################################################
# フォローリスト取得

my $max_id;
for(;;){
	my $path = "/api/v1/accounts/$me->{id}/following";
	defined($max_id) and $path .= "?max_id=$max_id";
	my($data,$res)= getApi( $path );
	if($data){
		for(@$data){
			say $_->{acct};
		}
	}
	my $link_header = $res->header('Link');
	last if not $link_header;
	last if not $link_header or not $link_header =~ /max_id=(\d+)/;
	$max_id = $1;
}
