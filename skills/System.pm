package skills::System;
use strict;
use warnings;
use File::Slurper qw(write_text read_text);

my $config = do 'config.pl' or die "Could not load config.pl: $!";
my $PROJECTS_ROOT = $config->{projects_root};

sub _resolve_path {
    my ($path) = @_;
    return $path if !$path || $path =~ m{^/}; # Absolute path
    return "$PROJECTS_ROOT/$path" unless $path =~ s{^/?projects/}{};
    return "$PROJECTS_ROOT/$path";
}

sub register {
    return {
        'write_file' => {
            description => "Write content to a file. DO NOT use this for C code in ESP-IDF projects; use 'esp_write_main_source' instead.",
            parameters => {
                type => "object",
                properties => {
                    path => { type => "string" },
                    content => { type => "string" }
                },
                required => ["path", "content"]
            },
            code => sub { 
                my ($args) = @_;
                my $path = _resolve_path($args->{path});
                write_text($path, $args->{content});
                return "File written: $path";
            }
        },
        'read_file' => {
            description => "Read a file's content",
            parameters => {
                type => "object",
                properties => { path => { type => "string" } },
                required => ["path"]
            },
            code => sub { 
                my ($args) = @_;
                my $path = _resolve_path($args->{path});
                if (-f $path) {
                    return read_text($path);
                }
                else {
                    my $dir = $PROJECTS_ROOT;
                    my $ls_out = `ls -l $dir`;
                    return "Error: File not found at '$path'.\n\nDirectory listing for '$dir':\n$ls_out";
                }
            }
        },
        'run_shell' => {
            description => "Execute a Linux shell command (foreground)",
            parameters => {
                type => "object",
                properties => { command => { type => "string" } },
                required => ["command"]
            },
            code => sub {
                my ($args) = @_;
                my $out = `$args->{command} 2>&1`;
                return $out;
            }
        },
        'google_search' => {
            description => "Perform a search for technical information using DuckDuckGo.",
            parameters => {
                type => "object",
                properties => { query => { type => "string" } },
                required => ["query"]
            },
            code => sub {
                my ($args) = @_;
                my $q = $args->{query};
                my $out = `ddgr -n 5 --json "$q" 2>/dev/null`;
                if (!$out || $out eq "[]") {
                    return "No results found for '$q'.";
                }
                return $out;
            }
        },
        'replace_in_file' => {
            description => "Surgically replace a string in a file. Use this for small fixes instead of rewriting the whole file.",
            parameters => {
                type => "object",
                properties => {
                    path => { type => "string" },
                    old_string => { type => "string", description => "The exact text to find." },
                    new_string => { type => "string", description => "The text to replace it with." }
                },
                required => ["path", "old_string", "new_string"]
            },
            code => sub {
                my ($args) = @_;
                my $path = _resolve_path($args->{path});
                my $content = read_text($path);
                my ($old, $new) = ($args->{old_string}, $args->{new_string});
                if ($content =~ s/\Q$old\E/$new/) {
                    write_text($path, $content);
                    return "Successfully replaced text in $path";
                } else {
                    return "Error: Could not find exact match for 'old_string' in $path";
                }
            }
        }
    };
}
1;
