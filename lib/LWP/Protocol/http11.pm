# $Id: http11.pm,v 1.14 2001/04/28 07:11:12 gisle Exp $
#
# You can tell LWP to use this module for 'http' requests by running
# code like this before you make requests:
#
#    require LWP::Protocol::http11;
#    LWP::Protocol::implementor('http', 'LWP::Protocol::http11');

package LWP::Protocol::http11;

use strict;

require LWP::Debug;
require HTTP::Response;
require HTTP::Status;
require Net::HTTP;

use vars qw(@ISA @EXTRA_SOCK_OPTS);

require LWP::Protocol;
@ISA = qw(LWP::Protocol);

my $CRLF = "\015\012";

{
    package LWP::Protocol::MyHTTP;
    use vars qw(@ISA);
    @ISA = qw(Net::HTTP);

    sub xread {
	my $self = shift;
	if (my $timeout = ${*$self}{io_socket_timeout}) {
	    my $io_sel = (${*$self}{myhttp_io_sel} ||= $self->io_sel);
	    die "read timeout" unless $io_sel->can_read($timeout);
	}
	sysread($self, $_[0], $_[1], $_[2] || 0);
    }

    sub io_sel {
	my $self = shift;
	my $io_sel = (${*$self}{myhttp_io_sel} ||=
		      do {
			  require IO::Select;
			  IO::Select->new($self);
		      });
	return $io_sel;
    }

    sub ping {
	my $self = shift;
	!$self->io_sel->can_read(0);
    }
}

sub _new_socket
{
    my($self, $host, $port, $timeout) = @_;
    my $conn_cache = $self->{ua}{conn_cache};
    if ($conn_cache) {
	if (my $sock = $conn_cache->withdraw("http", "$host:$port")) {
	    return $sock if $sock && !$sock->io_sel->can_read(0);
	    # if the socket is readable, then either the peer has closed the
	    # connection or there are some garbage bytes on it.  In either
	    # case we abandon it.
	    $sock->close;
	}
    }

    local($^W) = 0;  # IO::Socket::INET can be noisy
    my $sock = LWP::Protocol::MyHTTP->new(PeerAddr => $host,
					  PeerPort => $port,
					  Proto    => 'tcp',
					  Timeout  => $timeout,
					  KeepAlive => !!$conn_cache,
					  $self->_extra_sock_opts($host, $port),
					 );
    unless ($sock) {
	# IO::Socket::INET leaves additional error messages in $@
	$@ =~ s/^.*?: //;
	die "Can't connect to $host:$port ($@)";
    }
    $sock->blocking(0);
    $sock;
}

sub _extra_sock_opts  # to be overridden by subclass
{
    return @EXTRA_SOCK_OPTS;
}

sub _check_sock
{
    #my($self, $req, $sock) = @_;
}

sub _get_sock_info
{
    my($self, $res, $sock) = @_;
    #if (defined(my $peerhost = $sock->peerhost)) {
    #    $res->header("Client-Peer" => "$peerhost:" . $sock->peerport);
    #}
}

sub _fixup_header
{
    my($self, $h, $url, $proxy) = @_;

    # Extract 'Host' header
    my $hhost = $url->authority;
    $hhost =~ s/^([^\@]*)\@//;  # get rid of potential "user:pass@"
    $h->header('Host' => $hhost) unless defined $h->header('Host');

    # add authorization header if we need them.  HTTP URLs do
    # not really support specification of user and password, but
    # we allow it.
    if (defined($1) && not $h->header('Authorization')) {
	require URI::Escape;
	$h->authorization_basic(map URI::Escape::uri_unescape($_),
				split(":", $1, 2));
    }

    if ($proxy) {
	# Check the proxy URI's userinfo() for proxy credentials
	# export http_proxy="http://proxyuser:proxypass@proxyhost:port"
	my $p_auth = $proxy->userinfo();
	if(defined $p_auth) {
	    require URI::Escape;
	    $h->proxy_authorization_basic(map URI::Escape::uri_unescape($_),
					  split(":", $p_auth, 2))
	}
    }
}

sub hlist_remove {
    my($hlist, $k) = @_;
    $k = lc $k;
    for (my $i = @$hlist - 2; $i >= 0; $i -= 2) {
	next unless lc($hlist->[$i]) eq $k;
	splice(@$hlist, $i, 2);
    }
}

sub request
{
    my($self, $request, $proxy, $arg, $size, $timeout) = @_;
    LWP::Debug::trace('()');

    $size ||= 4096;

    # check method
    my $method = $request->method;
    unless ($method =~ /^[A-Za-z0-9_!\#\$%&\'*+\-.^\`|~]+$/) {  # HTTP token
	return new HTTP::Response &HTTP::Status::RC_BAD_REQUEST,
				  'Library does not allow method ' .
				  "$method for 'http:' URLs";
    }

    my $url = $request->url;
    my($host, $port, $fullpath);

    # Check if we're proxy'ing
    if (defined $proxy) {
	# $proxy is an URL to an HTTP server which will proxy this request
	$host = $proxy->host;
	$port = $proxy->port;
	$fullpath = $method eq "CONNECT" ?
                       ($url->host . ":" . $url->port) :
                       $url->as_string;
    }
    else {
	$host = $url->host;
	$port = $url->port;
	$fullpath = $url->path_query;
	$fullpath = "/" unless length $fullpath;
    }

    # connect to remote site
    my $socket = $self->_new_socket($host, $port, $timeout);
    $self->_check_sock($request, $socket);

    my @h;
    my $request_headers = $request->headers;
    $request_headers->scan(sub { push(@h, @_); });

    my $content_ref = $request->content_ref;
    $content_ref = $$content_ref if ref($$content_ref);
    my $chunked;
    my $has_content;

    if (ref($content_ref) eq 'CODE') {
	my $clen = $request_headers->header('Content-Length');
	$has_content++ if $clen;
	unless (defined $clen) {
	    push(@h, "Transfer-Encoding" => "chunked");
	    $has_content++;
	    $chunked++;
	}
    } else {
	# Set (or override) Content-Length header
	my $clen = $request_headers->header('Content-Length');
	if (defined($$content_ref) && length($$content_ref)) {
	    $has_content++;
	    if (!defined($clen) || $clen ne length($$content_ref)) {
		if (defined $clen) {
		    warn "Content-Length header value was wrong, fixed";
		    hlist_remove(\@h, 'Content-Length');
		}
		push(@h, 'Content-Length' => length($$content_ref));
	    }
	}
	elsif ($clen) {
	    warn "Content-Length set when there is not content, fixed";
	    hlist_remove(\@h, 'Content-Length');
	}
    }

    my $req_buf = $socket->format_request($method, $fullpath, @h);

    # XXX need to watch out for write timeouts
    {
	my $n = $socket->syswrite($req_buf, length($req_buf));
	die $! unless defined($n);
	die "short write" unless $n == length($req_buf);
	#LWP::Debug::conns($req_buf);
    }

    my($code, $mess);
    my $drop_connection;

    if ($has_content) {
	my $write_wait = 0;
	$write_wait = 2
	    if ($request_headers->header("Expect") || "") =~ /100-continue/;

	my $eof;
	my $wbuf;
	my $woffset = 0;
	if (ref($content_ref) eq 'CODE') {
	    my $buf = &$content_ref();
	    $buf = "" unless defined($buf);
	    $buf = sprintf "%x%s%s%s", length($buf), $CRLF, $buf, $CRLF
		if $chunked;
	    $wbuf = \$buf;
	}
	else {
	    $wbuf = $content_ref;
	    $eof = 1;
	}

	my $io_sel = $socket->io_sel;

	while ($woffset < length($$wbuf)) {

	    my $time_before;
	    my $sel_timeout = $timeout;
	    if ($write_wait) {
		$time_before = time;
		$sel_timeout = $write_wait if $write_wait < $sel_timeout;
	    }

	    my($r, $w) = IO::Select::select($io_sel,
					    ($write_wait ? undef : $io_sel),
					    undef,
					    $sel_timeout);

	    if ($write_wait) {
		$write_wait -= time - $time_before;
		$write_wait = 0 if $write_wait < 0;
	    }

	    if ($r && @$r) {
		# readable
		my $buf = $socket->_rbuf;
		my $n = sysread($socket, $buf, 1024, length($buf));
		unless ($n) {
		    die "EOF";
		}
		$socket->_rbuf($buf);
		if ($buf =~ /\015?\012\015?\012/) {
		    # a whole response present
		    ($code, $mess, @h) = $socket->read_response_headers;
		    if ($code eq "100") {
			$write_wait = 0;
			undef($code);
		    }
		    else {
			$drop_connection++;
			last;
			# XXX should perhaps try to abort write in a nice way too
		    }
		}
	    }
	    if ($w && @$w) {
		my $n = $socket->syswrite($$wbuf, length($$wbuf), $woffset);
		unless ($n) {
		    die "syswrite: $!" unless defined $n;
		    die "syswrite: no bytes written";
		}
		$woffset += $n;

		if (!$eof && $woffset >= length($$wbuf)) {
		    # need to refill buffer from $content_ref code
		    my $buf = &$content_ref();
		    $buf = "" unless defined($buf);
		    $eof++ unless length($buf);
		    $buf = sprintf "%x%s%s%s", length($buf), $CRLF, $buf, $CRLF
			if $chunked;
		    $wbuf = \$buf;
		    $woffset = 0;
		}
	    }
	}
    }

    ($code, $mess, @h) = $socket->read_response_headers
	unless $code;

    my $response = HTTP::Response->new($code, $mess);
    my $peer_http_version = $socket->peer_http_version;
    $response->protocol("HTTP/$peer_http_version");
    while (@h) {
	my($k, $v) = splice(@h, 0, 2);
	$response->push_header($k, $v);
    }

    $response->request($request);
    $self->_get_sock_info($response, $socket);

    if ($method eq "CONNECT") {
	$response->{client_socket} = $socket;  # so it can be picked up
	return $response;
    }

    #$response->remove_header('Transfer-Encoding');
    $response->push_header('Client-Warning', 'LWP HTTP/1.1 support is experimental');
    $response->push_header('Client-Request-Num', ++${*$socket}{'myhttp_req_count'});

    my $complete;
    $response = $self->collect($arg, $response, sub {
	my $buf;
	my $n = $socket->read_entity_body($buf, $size);
	die $! unless defined $n;
	$complete++ if !$n;
	if ($n eq "0E0") {
	    $buf = "x"; # XXX need to change this interface somehow...
	}
        return \$buf;
    } );
    $drop_connection++ unless $complete;

    @h = $socket->get_trailers;
    while (@h) {
	my($k, $v) = splice(@h, 0, 2);
	$response->push_header($k, $v);
    }

    # keep-alive support
    unless ($drop_connection) {
	if (my $conn_cache = $self->{ua}{conn_cache}) {
	    my %connection = map { (lc($_) => 1) }
		             split(/\s*,\s*/, ($response->header("Connection") || ""));
	    if (($peer_http_version eq "1.1" && !$connection{close}) ||
		$connection{"keep-alive"})
	    {
		LWP::Debug::debug("Keep the http connection to $host:$port");
		$conn_cache->deposit("http", "$host:$port", $socket);
	    }
	}
    }

    $response;
}

1;