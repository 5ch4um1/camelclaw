#!/usr/bin/perl
use strict;
use warnings;
use lib './lib';
use Camel::Brain;
use JSON::MaybeXS;

# Mock HTTP response to simulate the local model error
{
    package MockHTTP;
    use JSON::MaybeXS;
    sub new { bless {}, shift }
    sub post {
        my ($self, $url, $args) = @_;
        my $payload = decode_json($args->{content});
        my @messages = @{$payload->{messages}};
        
        my $last_role = "";
        foreach my $msg (@messages) {
            my $role = $msg->{role};
            next if $role eq 'system'; 
            
            # If role is tool, it must follow assistant
            if ($role eq 'tool') {
                if ($last_role ne 'assistant' && $last_role ne 'tool') {
                    return {
                        success => 0,
                        status => 400,
                        content => '{"error":{"message":"Tool message must follow assistant message"}}'
                    };
                }
                $last_role = 'tool';
                next;
            }

            if ($role eq $last_role) {
                return {
                    success => 0,
                    status => 400,
                    content => '{"error":{"message":"Conversation roles must alternate user/assistant/user/assistant/..."}}'
                };
            }
            $last_role = $role;
        }
        
        return {
            success => 1,
            status => 200,
            content => encode_json({ choices => [{ message => { content => "Success!" } }] })
        };
    }
}

my $brain = Camel::Brain->new(model => 'local-qwen');
$brain->{http} = MockHTTP->new();

my $history = [
    { role => "user", parts => [{ text => "Hello" }] },
    { role => "user", parts => [{ text => "World" }] }, # This should trigger the error
];

print "Testing with two consecutive user messages...
";
eval {
    $brain->chat($history, "System instruction", {});
};
if ($@) {
    print "Caught expected error: $@
";
} else {
    print "Unexpected success!
";
}

$history = [
    { role => "user", parts => [{ text => "Hello" }] },
    { role => "model", parts => [{ text => "Hi" }] },
    { role => "user", parts => [{ text => "World" }] },
];

print "\nTesting with alternating roles...\n";
eval {
    my $res = $brain->chat($history, "System instruction", {});
    print "Response: " . $res->{parts}[0]{text} . "\n";
};
if ($@) {
    print "Caught unexpected error: $@\n";
}

$history = [
    { role => "user", parts => [{ text => "Hello" }] },
    { role => "model", parts => [{ text => "Hi" }] },
    { role => "model", parts => [{ text => "How can I help?" }] },
];

print "\nTesting with two consecutive assistant messages...\n";
eval {
    my $res = $brain->chat($history, "System instruction", {});
    print "Response: " . $res->{parts}[0]{text} . "\n";
};
if ($@) {
    print "Caught unexpected error: $@\n";
}
