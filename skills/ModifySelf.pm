package skills::ModifySelf;
use strict;
use warnings;
use File::Slurper qw(write_text read_text);

sub register {
    return {
        'modify_agent_code' => {
            description => "Modify a file within the agent's own codebase (lib/Camel/ or camelclaw.pl)",
            parameters => {
                type => "object",
                properties => {
                    path => { type => "string", description => "The path to the file to modify (e.g., lib/Camel/Brain.pm)" },
                    new_content => { type => "string", description => "The full content to write to the file" }
                },
                required => ["path", "new_content"]
            },
            code => sub {
                my ($args) = @_;
                my $path = $args->{path};
                if ($path !~ /^(lib\/Camel\/|skills\/|camelclaw\.pl)/) {
                    return "Error: You can only modify the agent's own files (lib/Camel/, skills/, camelclaw.pl).";
                }
                write_text($path, $args->{new_content});
                return "Successfully modified: $path";
            }
        },
        'read_agent_code' => {
            description => "Read a file from the agent's own codebase",
            parameters => {
                type => "object",
                properties => {
                    path => { type => "string", description => "The path to the file to read" }
                },
                required => ["path"]
            },
            code => sub {
                my ($args) = @_;
                my $path = $args->{path};
                if ($path !~ /^(lib\/Camel\/|skills\/|camelclaw\.pl)/) {
                    return "Error: You can only read the agent's own files.";
                }
                return read_text($path);
            }
        }
    };
}
1;
