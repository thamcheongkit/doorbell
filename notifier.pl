#!/usr/bin/perl
# Listens on localhost and shows POSTed messages as macOS notifications.
use strict;
use warnings;
use Encode qw(encode_utf8);
use IO::Socket::INET;
use JSON::PP;

my $PORT     = $ENV{NOTIFIER_PORT} // 8765;
my $MAX_BODY = 64 * 1024;
my $TIMEOUT  = 5;

# Text is passed as arguments, never interpolated, so it can't inject AppleScript.
my $APPLESCRIPT = <<'END';
on run argv
    display notification (item 2 of argv) with title (item 1 of argv)
end run
END

$SIG{PIPE} = 'IGNORE';

my $server = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => $PORT,
    Listen    => 16,
    ReuseAddr => 1,
    Proto     => 'tcp',
) or die "cannot listen on 127.0.0.1:$PORT: $!\n";

print STDERR "macos-notifier listening on 127.0.0.1:$PORT\n";

while (my $client = $server->accept) {
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $TIMEOUT;
        my ($status, $body) = handle($client);
        alarm 0;
        respond($client, $status, $body);
    };
    alarm 0;
    print STDERR "request failed: $@" if $@;
    close $client;
}

sub handle {
    my ($client) = @_;

    my $request_line = <$client> // return (400, { error => 'empty request' });
    my ($method, $path) = $request_line =~ m{^(\S+) (\S+) HTTP/1\.[01]\r?\n$}
        or return (400, { error => 'malformed request' });

    my %headers;
    while (my $line = <$client>) {
        last if $line =~ /^\r?\n$/;
        $headers{lc $1} = $2 if $line =~ /^([^:]+):\s*(.*?)\r?\n$/;
    }

    # Browsers send Origin on cross-site requests; this stops any web page
    # you visit from POSTing to localhost.
    return (403, { error => 'browser requests are not allowed' }) if exists $headers{origin};

    return (200, { status => 'ok' }) if $method eq 'GET' && $path eq '/health';
    return (404, { error => 'not found' }) unless $path eq '/notify';
    return (405, { error => 'use POST' })  unless $method eq 'POST';

    my $length = $headers{'content-length'} // '';
    return (411, { error => 'content-length required' }) unless $length =~ /^\d+$/;
    return (413, { error => 'body too large' })          if $length > $MAX_BODY;

    read($client, my $raw, $length) == $length
        or return (400, { error => 'incomplete body' });

    my $data = eval { JSON::PP->new->utf8->decode($raw) };
    return (400, { error => 'body must be a JSON object' }) unless ref $data eq 'HASH';

    my $message = $data->{message};
    return (400, { error => 'message is required' })
        unless defined $message && !ref $message && length $message;

    my $title = $data->{title};
    $title = 'Notifier' unless defined $title && !ref $title && length $title;

    my $exit = system('/usr/bin/osascript', '-e', $APPLESCRIPT, '--',
        encode_utf8("$title"), encode_utf8("$message"));
    return (500, { error => 'osascript failed' }) if $exit != 0;

    return (200, { status => 'sent' });
}

sub respond {
    my ($client, $status, $body) = @_;
    my %reason = (
        200 => 'OK', 400 => 'Bad Request', 403 => 'Forbidden', 404 => 'Not Found',
        405 => 'Method Not Allowed', 411 => 'Length Required',
        413 => 'Payload Too Large', 500 => 'Internal Server Error',
    );
    my $json = JSON::PP->new->utf8->encode($body);
    print $client "HTTP/1.1 $status $reason{$status}\r\n"
        . "Content-Type: application/json\r\n"
        . 'Content-Length: ' . length($json) . "\r\n"
        . "Connection: close\r\n\r\n$json";
}
