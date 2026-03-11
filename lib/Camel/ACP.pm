package Camel::ACP;
use strict;
use warnings;
use IPC::Open3;
use IO::Select;
use JSON;
use Symbol 'gensym';
use Time::HiRes qw(time sleep);
use POSIX ":sys_wait_h";
use Term::ANSIColor;
use IO::Handle;

sub new {
    my ($class, %args) = @_;
    my $model = $args{model} || "gemini-2.5-flash";
    my $self = {
        # Using --approval-mode=yolo for autonomous tool execution
        cmd      => "gemini --experimental-acp --approval-mode=yolo --model $model",
        cwd      => $args{cwd} || ".",
        timeout  => $args{timeout} || 120,
        id_counter => 1,
        initialized => 0,
        session_id => undef,
        log_file => "logs/acp_debug.log",
        finished_requests => {},
        update_buffer => [],
        stdout_buf => "",
        stderr_buf => "",
    };
    mkdir "logs" unless -d "logs";
    return bless $self, $class;
}

sub _log {
    my ($self, $msg) = @_;
    open my $fh, '>>', $self->{log_file};
    print $fh "[".localtime()."] $msg\n";
    close $fh;
}

sub start {
    my ($self) = @_;
    my ($stdin, $stdout, $stderr);
    $stderr = gensym;
    
    $self->_log("Spawning: $self->{cmd}");
    my $pid = eval { open3($stdin, $stdout, $stderr, $self->{cmd}) };
    if ($@) {
        $self->_log("Spawn failed: $@");
        die "Failed to spawn Gemini ACP: $@";
    }
    
    $self->{pid} = $pid;
    $self->{stdin} = $stdin;
    $self->{stdout} = $stdout;
    $self->{stderr} = $stderr;
    
    # Set non-blocking
    $self->{stdout}->blocking(0);
    $self->{stderr}->blocking(0);
    
    $self->{sel} = IO::Select->new($stdout, $stderr);
    
    # 1. Initialize
    my $res = $self->call("initialize", {
        protocolVersion => 1,
        clientInfo => { name => "CamelClaw", version => "1.0.0" }
    });
    
    if ($res->{error}) {
        $self->_log("Initialize Error: " . encode_json($res->{error}));
        die "ACP Initialize Error: " . ($res->{error}->{message} || "Unknown error");
    }
    
    # 2. Initialized Notification
    $self->notify("initialized", {});
    $self->{initialized} = 1;
    
    # 3. Create Session
    my $s_res = $self->call("session/new", {
        cwd => $self->{cwd},
        mcpServers => [],
        authId => "oauth-personal",
        approvalMode => "yolo"
    });
    
    if ($s_res->{error}) {
        $self->_log("Session Error: " . encode_json($s_res->{error}));
        die "ACP Session Error: " . ($s_res->{error}->{message} || "Unknown error");
    }
    
    $self->{session_id} = $s_res->{result}->{sessionId};
    $self->_log("Session created: $self->{session_id}");
    return $self->{session_id};
}

sub load_session {
    my ($self, $session_id) = @_;
    my ($stdin, $stdout, $stderr);
    $stderr = gensym;
    
    my $pid = open3($stdin, $stdout, $stderr, $self->{cmd});
    $self->{pid} = $pid;
    $self->{stdin} = $stdin;
    $self->{stdout} = $stdout;
    $self->{stderr} = $stderr;
    $self->{stdout}->blocking(0);
    $self->{stderr}->blocking(0);
    $self->{sel} = IO::Select->new($stdout, $stderr);
    
    # 1. Initialize
    $self->call("initialize", {
        protocolVersion => 1,
        clientInfo => { name => "CamelClaw", version => "1.0.0" }
    });
    
    # 2. Initialized Notification
    $self->notify("initialized", {});
    $self->{initialized} = 1;
    
    # 3. Load Session
    my $s_res = $self->call("session/load", {
        sessionId => $session_id
    });
    
    if ($s_res->{error}) {
        die "ACP Session Load Error: " . ($s_res->{error}->{message} || "Unknown error");
    }
    
    $self->{session_id} = $session_id;
    return $self->{session_id};
}

sub call {
    my ($self, $method, $params, $is_async) = @_;
    my $id = $self->{id_counter}++;
    my $req = {
        jsonrpc => "2.0",
        id      => $id,
        method  => $method,
        params  => $params
    };
    
    my $json = encode_json($req) . "\n";
    $self->_log("REQ [$id]: $json");
    print { $self->{stdin} } $json;
    
    return $id if $is_async;
    return $self->wait_for_response($id);
}

sub notify {
    my ($self, $method, $params) = @_;
    my $req = {
        jsonrpc => "2.0",
        method  => $method,
        params  => $params
    };
    my $json = encode_json($req) . "\n";
    $self->_log("NOTIFY: $json");
    print { $self->{stdin} } $json;
}

sub prompt {
    my ($self, $text, $is_async) = @_;
    die "ACP not started" unless $self->{session_id};
    
    $is_async ||= 0;
    $self->_log("PROMPT ($is_async): $text");
    
    my $id_or_res = $self->call("session/prompt", {
        sessionId => $self->{session_id},
        prompt => [{ type => "text", text => $text }]
    }, $is_async);
    
    if ($is_async) {
        return { requestId => $id_or_res };
    }
    
    my $res = $id_or_res;
    my $full_text = join("", @{$self->{update_buffer}});
    $self->{update_buffer} = [];
    
    return { text => $full_text, result => $res->{result}, error => $res->{error} };
}

sub poll {
    my ($self) = @_;
    my @new_chunks;
    
    foreach my $type (qw(stdout stderr)) {
        my $fh = $self->{$type};
        next unless $fh;
        
        while ($self->{sel}->can_read(0)) {
            my $bytes = sysread($fh, my $chunk, 8192);
            if (defined $bytes && $bytes > 0) {
                $self->{"${type}_buf"} .= $chunk;
            } else {
                # Handle error or EOF
                last; 
            }
        }
        
        # Process full lines
        while ($self->{"${type}_buf"} =~ s/^(.*?)\n//) {
            my $line = $1;
            if ($type eq 'stderr') {
                $self->_log("STDERR: $line");
                next;
            }
            
            $self->_log("RECV: $line");
            my $data = eval { decode_json($line) };
            if ($@) {
                $self->_log("JSON Decode Error: $@ (Line: $line)");
                next;
            }
            
            if ($data->{id}) {
                $self->{finished_requests}->{$data->{id}} = $data;
            }
            
            if ($data->{method} && $data->{method} eq 'session/update') {
                my $text = $self->_parse_update($data->{params}->{update});
                if ($text) {
                    push @{$self->{update_buffer}}, $text;
                    push @new_chunks, $text;
                }
            }
        }
    }
    return @new_chunks;
}

sub _parse_update {
    my ($self, $update) = @_;
    my $type = $update->{sessionUpdate};
    
    if ($type eq 'agent_message_chunk') {
         my $content = $update->{content};
         if ($content && $content->{type} eq 'text') {
             return color('bold magenta') . $content->{text} . color('reset');
         }
    } elsif ($type eq 'tool_call') {
         return "\n" . color('bold cyan') . "  [Action: $update->{title}]" . color('reset') . "\n";
    } elsif ($type eq 'tool_call_update' && $update->{status} eq 'completed') {
         my $res = color('bold green') . "  [Action Finished]" . color('reset') . "\n";
         
         # CAPTURE TOOL OUTPUT
         my $content_list = $update->{content} || [];
         foreach my $c (@$content_list) {
             if ($c->{type} eq 'content') {
                 my $inner = $c->{content};
                 if ($inner && $inner->{type} eq 'text') {
                     my $out_text = $inner->{text};
                     $out_text =~ s/^/    /mg; # Indent output
                     $res .= color('bold yellow') . "  [Output]:\n" . color('reset') . $out_text . "\n";
                 }
             }
         }
         return $res;
    }
    return "";
}

sub wait_for_response {
    my ($self, $id) = @_;
    my $start_time = time();
    
    while (time() - $start_time < $self->{timeout}) {
        $self->poll();
        if ($self->{finished_requests}->{$id}) {
            return delete $self->{finished_requests}->{$id};
        }
        
        # Check if process died
        if ($self->{pid} && waitpid($self->{pid}, WNOHANG) != 0) {
            $self->_log("Child process $self->{pid} died unexpectedly.");
            $self->poll(); # Last drain
            if ($self->{finished_requests}->{$id}) {
                return delete $self->{finished_requests}->{$id};
            }
            return { id => $id, error => { message => "Gemini process died unexpectedly." } };
        }
        
        sleep(0.05);
    }
    $self->_log("Timeout waiting for response to ID $id");
    return { id => $id, error => { message => "Request timeout ($id)" } };
}

sub is_finished {
    my ($self, $request_id) = @_;
    $self->poll();
    return 1 if exists $self->{finished_requests}->{$request_id};
    
    # Check if process died
    if ($self->{pid} && waitpid($self->{pid}, WNOHANG) != 0) {
        $self->_log("Process $self->{pid} dead in is_finished.");
        $self->poll(); # One last poll to get any final data
        if (exists $self->{finished_requests}->{$request_id}) {
            return 1;
        }
        # Process died without sending the packet we wanted
        $self->{finished_requests}->{$request_id} = {
            id => $request_id,
            error => { message => "Agent process terminated unexpectedly." }
        };
        return 1;
    }
    
    return 0;
}

sub get_result {
    my ($self, $request_id) = @_;
    my $res = delete $self->{finished_requests}->{$request_id};
    return undef unless $res;
    
    my $full_text = join("", @{$self->{update_buffer}});
    $self->{update_buffer} = [];
    
    return { text => $full_text, result => $res->{result}, error => $res->{error} };
}

sub stop {
    my ($self) = @_;
    if ($self->{pid}) {
        $self->_log("Stopping process $self->{pid}");
        kill 'TERM', $self->{pid};
        # Give it a second to die gracefully
        my $waited = 0;
        while ($waited < 10 && waitpid($self->{pid}, WNOHANG) == 0) {
            sleep(0.1);
            $waited++;
        }
        if (waitpid($self->{pid}, WNOHANG) == 0) {
            $self->_log("Process $self->{pid} didn't respond to TERM, using KILL");
            kill 'KILL', $self->{pid};
            waitpid($self->{pid}, 0);
        }
        $self->{pid} = undef;
    }
}

sub DESTROY {
    my ($self) = @_;
    $self->stop();
}

1;
