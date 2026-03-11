package skills::GeminiACP;
use strict;
use warnings;
use Camel::ACP;
use JSON;
use Term::ANSIColor;
use Time::HiRes qw(sleep);

# We'll store active ACP instances here
my %instances;
# Track pending async request IDs for each agent
my %pending_reqs;

# Interleaving control
my $last_active_id = "";
my %agent_line_buffers;

sub register {
    return {
        'acp_spawn_agent' => {
            description => "Spawn a Gemini sub-agent for a specific task.",
            parameters => {
                type => "object",
                properties => {
                    id => { type => "string", description => "A unique ID for this instance." },
                    task => { type => "string", description => "The task/prompt." },
                    model => { type => "string", description => "Model to use." },
                    is_async => { type => "boolean", description => "If true, return immediately without waiting for the task to finish." }
                },
                required => ["id", "task"]
            },
            code => \&spawn_acp
        },
        'acp_query_agent' => {
            description => "Send a prompt to an existing sub-agent.",
            parameters => {
                type => "object",
                properties => {
                    id => { type => "string", description => "The unique ID of the agent." },
                    prompt => { type => "string", description => "The prompt." },
                    is_async => { type => "boolean", description => "If true, return immediately." }
                },
                required => ["id", "prompt"]
            },
            code => \&query_acp
        },
        'acp_wait_all' => {
            description => "Wait for all pending async agent tasks to complete and return a combined report.",
            parameters => {
                type => "object",
                properties => {
                    timeout => { type => "integer", description => "Max time to wait in seconds (default 120)." },
                    show_live => { type => "boolean", description => "If true, print sub-agent updates to the console as they happen." }
                }
            },
            code => \&wait_all_acp
        },
        'acp_stop_agent' => {
            description => "Stop and cleanup an ACP sub-agent.",
            parameters => {
                type => "object",
                properties => {
                    id => { type => "string", description => "The unique ID of the sub-agent." }
                },
                required => ["id"]
            },
            code => \&stop_acp
        }
    };
}

sub _wrap_output {
    my ($id, $output) = @_;
    my $header = color('on_magenta white') . " --- SUB-AGENT START ($id) --- " . color('reset') . "\n";
    my $footer = "\n" . color('on_magenta white') . " --- SUB-AGENT END   ($id) --- " . color('reset');
    return $header . $output . $footer;
}

sub spawn_acp {
    my ($args, $kernel) = @_;
    my ($id, $task, $model, $is_async) = ($args->{id}, $args->{task}, $args->{model}, $args->{is_async});
    
    if ($instances{$id}) {
        return "Error: Agent with ID '$id' already exists.";
    }
    
    my $acp = Camel::ACP->new(
        model => $model,
        cwd   => $kernel->{config}->{projects_root} || "."
    );
    
    eval { $acp->start(); };
    if ($@) { return "Error spawning ACP agent: $@"; }
    
    $instances{$id} = $acp;
    
    my $res = $acp->prompt($task, $is_async);
    
    if ($is_async) {
        $pending_reqs{$id} = $res->{requestId};
        return "Agent '$id' spawned and task started in background.";
    }
    
    my $output = $res->{text} || "";
    if ($res->{error}) {
        if ($output =~ /\[Action/ || length($output) > 20) {
             my $wrapped = _wrap_output($id, $output);
             return "ACP Agent '$id' spawned. Note: Empty output received, if you ran a command, this could mean success. (Interruption: " . ($res->{error}->{message} || "Unknown") . "). Result:\n$wrapped";
        }
        return "ACP Agent '$id' spawned but the task failed or timed out. Partial output: $output\nFailure: " . ($res->{error}->{message} || "Unknown");
    }
    
    my $wrapped = _wrap_output($id, $output);
    return "ACP Agent '$id' spawned. Response:\n$wrapped";
}

sub query_acp {
    my ($args, $kernel) = @_;
    my ($id, $prompt, $is_async) = ($args->{id}, $args->{prompt}, $args->{is_async});
    
    my $acp = $instances{$id};
    return "Error: Agent with ID '$id' not found." unless $acp;
    
    my $res = $acp->prompt($prompt, $is_async);
    
    if ($is_async) {
        $pending_reqs{$id} = $res->{requestId};
        return "Task sent to agent '$id' in background.";
    }
    
    my $output = $res->{text} || "";
    if ($res->{error}) {
        if ($output =~ /\[Action/ || length($output) > 20) {
             my $wrapped = _wrap_output($id, $output);
             return "ACP Agent '$id' responded. Note: Empty output received, if you ran a command, this could mean success. (Interruption: " . ($res->{error}->{message} || "Unknown") . "). Result:\n$wrapped";
        }
        return "ACP Query to agent '$id' failed or timed out. Partial output: $output\nFailure: " . ($res->{error}->{message} || "Unknown");
    }
    
    my $wrapped = _wrap_output($id, $output);
    return "ACP Agent '$id' Response:\n$wrapped";
}

sub wait_all_acp {
    my ($args, $kernel) = @_;
    my $timeout = $args->{timeout} || 120;
    my $show_live = $args->{show_live} // 1; 
    my $start_time = time();
    
    my @results;
    $last_active_id = "";
    %agent_line_buffers = ();

    while (keys %pending_reqs && (time() - $start_time < $timeout)) {
        foreach my $id (sort keys %pending_reqs) {
            my $acp = $instances{$id};
            my $req_id = $pending_reqs{$id};
            
            # Poll for live updates
            my @chunks = $acp->poll();
            if ($show_live && @chunks) {
                foreach my $chunk (@chunks) {
                    # If agent switched, force a newline if the previous chunk didn't have one
                    if ($id ne $last_active_id) {
                        print "\n" if $last_active_id ne "";
                        print color('bold white'), "[$id] ", color('reset');
                        $last_active_id = $id;
                    }
                    
                    # Clean up the chunk: remove internal resets that might break our prefixing
                    # and ensure internal newlines are prefixed too.
                    my $prefix = color('bold white') . "[$id] " . color('reset');
                    $chunk =~ s/\n/\n$prefix/g;
                    
                    print $chunk;
                }
            }
            
            if ($acp->is_finished($req_id)) {
                my $res = $acp->get_result($req_id);
                delete $pending_reqs{$id};
                
                my $output = $res->{text} || "";
                my $report = "";
                if ($res->{error}) {
                    $report = "Agent '$id' task failed/timed out. Result:\n" . _wrap_output($id, $output);
                } else {
                    $report = "Agent '$id' task completed. Response:\n" . _wrap_output($id, $output);
                }
                push @results, $report;
            }
        }
        sleep(0.05) if keys %pending_reqs;
    }
    
    # Flush a final newline if needed
    print "\n" if $last_active_id ne "";

    if (keys %pending_reqs) {
        push @results, "Warning: Some agents timed out: " . join(", ", keys %pending_reqs);
    }
    
    return @results ? join("\n\n", @results) : "No pending background tasks found.";
}

sub stop_acp {
    my ($args, $kernel) = @_;
    my $id = $args->{id};
    
    delete $pending_reqs{$id};
    my $acp = delete $instances{$id};
    return "Error: Agent with ID '$id' not found." unless $acp;
    
    $acp->stop();
    return "ACP Agent '$id' stopped.";
}

1;
