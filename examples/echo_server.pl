#!/usr/bin/env perl
use strict;
use warnings;
use lib 'lib';
use Linux::Event;
use Socket;

print "Linux::Event - Echo Server Example\n";
print "=" x 50, "\n\n";

my $loop = Linux::Event->new();
my $port = 9999;

# Create listening socket
socket(my $server, PF_INET, SOCK_STREAM, getprotobyname('tcp'))
    or die "socket: $!";
setsockopt($server, SOL_SOCKET, SO_REUSEADDR, pack("l", 1))
    or die "setsockopt: $!";
bind($server, sockaddr_in($port, INADDR_ANY))
    or die "bind: $!";
listen($server, SOMAXCONN)
    or die "listen: $!";

# Set non-blocking
use Fcntl;
my $flags = fcntl($server, F_GETFL, 0);
fcntl($server, F_SETFL, $flags | O_NONBLOCK);

print "Echo server listening on port $port\n";
print "Try: telnet localhost $port\n";
print "Type something and it will be echoed back!\n";
print "Press Ctrl-C to stop\n\n";

my $client_count = 0;
my %clients;

# Handle graceful shutdown
$loop->signal(
    signal => 'INT',
    cb => sub {
        print "\n\nShutting down...\n";
        print "Total clients served: $client_count\n";
        
        # Close all clients
        for my $client (values %clients) {
            close $client->{fh} if $client->{fh};
        }
        
        $loop->stop();
    }
);

# Accept connections
$loop->io(
    fh => $server,
    poll => 'r',
    cb => sub {
        my $client_addr = accept(my $client, $server);
        return unless $client_addr;
        
        # Set non-blocking
        my $flags = fcntl($client, F_GETFL, 0);
        fcntl($client, F_SETFL, $flags | O_NONBLOCK);
        
        my ($port, $iaddr) = sockaddr_in($client_addr);
        my $client_ip = inet_ntoa($iaddr);
        
        $client_count++;
        my $client_id = $client_count;
        
        print "[CLIENT $client_id] Connected from $client_ip:$port\n";
        
        # Send welcome message
        print $client "Welcome to the Echo Server!\n";
        print $client "Client ID: $client_id\n";
        print $client "Type 'quit' to disconnect\n";
        print $client "---\n";
        
        # Store client info
        $clients{$client_id} = {
            fh => $client,
            ip => $client_ip,
            port => $port,
            buffer => '',
        };
        
        # Read from client
        my $watcher = $loop->io(
            fh => $client,
            poll => 'r',
            data => { client_id => $client_id },
            cb => sub {
                my ($watcher, $revents) = @_;
                my $data = $watcher->data();
                my $cid = $data->{client_id};
                my $client_info = $clients{$cid};
                
                return unless $client_info;
                
                my $buf;
                my $n = sysread($client_info->{fh}, $buf, 4096);
                
                if (!defined $n) {
                    # Error
                    print "[CLIENT $cid] Read error\n";
                    $watcher->stop();
                    close $client_info->{fh};
                    delete $clients{$cid};
                    return;
                } elsif ($n == 0) {
                    # EOF
                    print "[CLIENT $cid] Disconnected\n";
                    $watcher->stop();
                    close $client_info->{fh};
                    delete $clients{$cid};
                    return;
                }
                
                $client_info->{buffer} .= $buf;
                
                # Process lines
                while ($client_info->{buffer} =~ s/^(.*?)\n//) {
                    my $line = $1;
                    $line =~ s/\r//g;
                    
                    if ($line eq 'quit') {
                        print "[CLIENT $cid] Quit command received\n";
                        print {$client_info->{fh}} "Goodbye!\n";
                        $watcher->stop();
                        close $client_info->{fh};
                        delete $clients{$cid};
                        return;
                    }
                    
                    # Echo back
                    print "[CLIENT $cid] Echo: $line\n";
                    print {$client_info->{fh}} "ECHO: $line\n";
                }
            }
        );
    }
);

# Show stats every 30 seconds
$loop->periodic(
    interval => 30,
    cb => sub {
        my $active = scalar keys %clients;
        print "[STATS] Total clients: $client_count, Active: $active\n";
    }
);

# Run the event loop
$loop->run();

print "Server stopped.\n";
