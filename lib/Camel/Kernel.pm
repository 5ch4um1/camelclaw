package Camel::Kernel;
use strict;
use warnings;
use JSON; # Changed from JSON::MaybeXS
use POSIX ":sys_wait_h";
use Camel::Brain;
use Term::ANSIColor;
use Term::ReadKey;
use Text::Wrap;
use Term::ReadLine;

# Disable default wrapping in Text::Wrap
$Text::Wrap::huge = 'overflow';
$Text::Wrap::break = qr/[\s\-]/;

sub new {
    my ($class, %args) = @_;
    my $self = {
        config     => $args{config} || {},
        brain      => Camel::Brain->new(
            project_id => $args{project_id} || $args{config}->{gcp_project_id},
            region     => $args{region}     || $args{config}->{gcp_region},
            local_url  => $args{local_url}   || $args{config}->{local_api_url},
        ),
        history    => [],
        processes  => {},
        skills     => {},
        max_turns  => $args{max_turns} || 1000,
        turn_count => 0,
        last_tool  => undef,
        repeat_count => 0,
        term       => Term::ReadLine->new('CamelClaw'),
    };
    $self->{term}->ornaments(0);
    return bless $self, $class;
}

sub register_skill {
    my ($self, $name, $tools) = @_;
    $self->wrap_print('green', "[Kernel] Registered skill: $name");
    foreach my $tool (keys %$tools) {
        $self->{skills}->{$tool} = $tools->{$tool};
    }
}

sub wrap_print {
    my ($self, $color, $text) = @_;
    my ($width, $height) = GetTerminalSize();
    $width ||= 80;
    local $Text::Wrap::columns = $width;
    my $wrapped = wrap('', '', $text);
    if ($color) {
        print color($color), $wrapped, color('reset'), "
";
    } else {
        print $wrapped, "
";
    }
}

sub push_history {
    my ($self, $role, $parts) = @_;
    $self->_log_to_session($role, $parts);
    if (@{$self->{history}} > 0 && $self->{history}->[-1]->{role} eq $role) {
        push @{$self->{history}->[-1]->{parts}}, @$parts;
    } else {
        push @{$self->{history}}, { role => $role, parts => $parts };
    }
}

sub _log_to_session {
    my ($self, $role, $parts) = @_;
    mkdir "logs" unless -d "logs";
    open my $fh, '>>', "logs/session.log" or return;
    my $timestamp = localtime();
    print $fh "[$timestamp] === $role ===
";
    foreach my $part (@$parts) {
        if ($part->{text}) {
            print $fh $part->{text} . "
";
        } elsif ($part->{functionCall}) {
            my $name = $part->{functionCall}->{name};
            my $args = encode_json($part->{functionCall}->{args});
            print $fh "CALL: $name($args)
";
        } elsif ($part->{functionResponse}) {
            my $name = $part->{functionResponse}->{name};
            my $res = encode_json($part->{functionResponse}->{response});
            print $fh "RESPONSE ($name): $res
";
        }
    }
    print $fh "
";
    close $fh;
}

sub get_boxed_input {
    my ($self, $title) = @_;
    
    my $tmp_file = "/tmp/camelclaw_input.txt";
    my $ui_script = "/tmp/camelclaw_ui.pl";
    unlink $tmp_file if -f $tmp_file;

    # Create an isolated Curses UI script
    # This ensures that when the script exits, the terminal state is restored by the shell
    open my $fh, '>', $ui_script or return $self->get_fallback_input($title);
    print $fh <<'EOF';
use strict;
use warnings;
use Curses::UI;
use File::Slurper qw(write_text);

my ($title, $output_path) = @ARGV;

my $cui = Curses::UI->new(-color_support => 1, -clear_on_exit => 1, -mouse_support => 1);
my $win = $cui->add('win', 'Window', -border => 1, -title => " $title ");

my $editor = $win->add(
    'ed', 'TextEditor',
    -wrapping => 1,
    -multiline => 1,
    -border => 1,
    -vscrollbar => 1,
    -width => $win->width() - 2,
    -height => $win->height() - 5,
    -y => 0, -x => 0,
);

$win->add(
    'h', 'Label',
    -text => " [Ctrl+O] Finish (Save) | [Ctrl+X] Quit | [Arrows] Navigate",
    -y => $win->height() - 3, -x => 1,
    -bold => 1, -fg => 'cyan',
);

my $finish = sub {
    my $text = $editor->get();
    write_text($output_path, $text);
    $cui->mainloop_exit();
};

$cui->set_binding($finish, "\cO");
$cui->set_binding($finish, "\cX");
$cui->set_binding($finish, "\cJ"); # Ctrl+Enter

$editor->focus();
$cui->mainloop();
EOF
    close $fh;

    # Execute the UI script in a sub-process
    # system() is safer than inline Curses for long-running scripts
    system("perl", $ui_script, $title, $tmp_file);
    
    my $result = "";
    if (-f $tmp_file) {
        use File::Slurper qw(read_text);
        $result = read_text($tmp_file);
        unlink $tmp_file;
    }
    unlink $ui_script;

    # Small delay and a simple clear to be safe
    select(undef, undef, undef, 0.1);
    print "\e[H\e[J"; # Standard ANSI clear

    if ($result eq "") {
        return $self->get_fallback_input($title);
    }
    
    return $result =~ /^\s*exit\s*$/i ? "exit" : $result;
}

sub get_fallback_input {
    my ($self, $title) = @_;
    my @lines = ("");
    my $cy = 0; my $cx = 0; 
    local $| = 1;
    print "
" . color('cyan') . "┌─────────────────── $title ───────────────────┐
" . color('reset');
    print "(Curses failed. Arrows: move, Ctrl+Enter: finish)
";
    ReadMode('cbreak');
    my $last_h = 0;
    while (1) {
        if ($last_h > 0) { print "\e[${last_h}A"; }
        for my $i (0 .. $#lines) { print "\e[K" . $lines[$i] . "
"; }
        $last_h = scalar(@lines);
        my $up = $last_h - $cy;
        print "\e[${up}A";
        print "\e[${cx}C" if $cx > 0;
        my $key = ReadKey(0);
        next unless defined $key;
        my $ord = ord($key);
        if ($ord == 10) { 
            my $down = $last_h - $cy;
            print "\e[${down}B
";
            last; 
        }
        elsif ($ord == 13) {
            my $post = substr($lines[$cy], $cx);
            $lines[$cy] = substr($lines[$cy], 0, $cx);
            splice(@lines, $cy + 1, 0, $post);
            $cy++; $cx = 0;
            print "
"; $last_h++;
        }
        elsif ($ord == 27) {
            my $n1 = ReadKey(-1);
            if (defined $n1 && ord($n1) == 91) {
                my $n2 = ReadKey(-1);
                if ($n2 eq 'A' && $cy > 0) { $cy--; $cx = length($lines[$cy]) if $cx > length($lines[$cy]); }
                elsif ($n2 eq 'B' && $cy < $#lines) { $cy++; $cx = length($lines[$cy]) if $cx > length($lines[$cy]); }
                elsif ($n2 eq 'C' && $cx < length($lines[$cy])) { $cx++; }
                elsif ($n2 eq 'D' && $cx > 0) { $cx--; }
            }
        }
        elsif ($ord == 127 || $ord == 8) {
            if ($cx > 0) { substr($lines[$cy], $cx - 1, 1, ""); $cx--; }
            elsif ($cy > 0) {
                my $old_len = length($lines[$cy-1]);
                $lines[$cy-1] .= splice(@lines, $cy, 1);
                $cy--; $cx = $old_len;
                print "\e[${last_h}A\e[J"; $last_h = 0;
            }
        }
        elsif ($ord >= 32 && $ord <= 126) { substr($lines[$cy], $cx, 0, $key); $cx++; }
    }
    ReadMode('normal');
    my $res = join("
", @lines); $res =~ s/\s+$//;
    return $res;
}

sub loop {
    my ($self, $initial_prompt) = @_;
    $self->push_history("user", [{ text => $initial_prompt }]);
    my $system_instruction = "You are CamelClaw, an autonomous Perl-based agent for Linux and ESP-IDF development. " .
                             "Your goal is to reach completion of the user's request autonomously. " .
                             "CRITICAL FILE OPERATIONS: All file paths you create, read, or modify MUST be relative to the 'projects/' directory (e.g., 'projects/my_script.py'). Do NOT assume the current working directory is 'projects/'.
" .
                             "HARDWARE SPECIFICS:
" .
                             "- Target: ESP32-C3
" .
                             "- Onboard Addressable LED: GPIO 10 (Use this for all blinky/rainbow tasks).
" .
                             "ESP-IDF V5.X GUIDELINES:
" .
                             "- For led_strip, use the 'espressif/led_strip' component.
" .
                             "- API: Use 'led_strip_new_rmt_device(&strip_config, &rmt_config, &led_strip)'.
" .
                             "- Built-in components: 'driver', 'esp_log', 'freertos' are ALREADY included. Do NOT add them with esp_idf_add_component.
" .
                             "CRITICAL SEQUENCING FOR ESP-IDF:
" .
                             "1. Create project (esp_create_project).
" .
                             "2. Set target IMMEDIATELY (esp_idf_cmd with action='set-target esp32c3'). This is mandatory for ESP32-C3.
" .
                             "3. Add components (esp_idf_add_component).
" .
                             "4. Write source code (esp_write_main_source). CRITICAL: Do NOT use 'write_file' for C code. Use 'esp_write_main_source' to ensure the code is placed in 'main/main.c'. Build will fail otherwise.
" .
                             "5. Build and Flash (esp_idf_cmd).
" .
                             "DEBUGGING PROTOCOL:
" .
                             "- If you see 'fatal error: XXX.h: No such file', it is a COMPILATION error. Do NOT check serial ports. Check your 'esp_idf_add_component' calls and your #include statements.
" .
                             "- If you see 'ninja: build stopped', the build failed. You MUST fix the source code or dependencies. Do NOT attempt to flash or monitor until the build is fixed.
" .
                             "- If you see 'Rebooting...', it is a runtime crash. Analyzes the 'abort()' or 'Panic' message in the logs.
" .
                             "- Always read the LAST 200 lines of logs carefully before deciding on your next move.
" .
                             "SUB-AGENT PARALLELISM:
" .
                             "- To run multiple agents SIMULTANEOUSLY, use 'acp_spawn_agent' or 'acp_query_agent' with 'is_async=true'.
" .
                             "- After firing off all async tasks, you MUST call 'acp_wait_all' to collect the results in parallel.
" .
                             "- Do NOT spawn agents sequentially if the user asks for parallel execution.
" .
                             "CRITICAL: If a tool returns an 'Error', 'Usage', or 'FAILED' message, you MUST stop, analyze the output, and fix the parameters in your next turn. Do not continue to the next step if the previous one failed.
" .
                             "Do not stop to ask for permission between steps unless you encounter a critical error you cannot solve. " .
                             "Once the entire goal is achieved and verified, summarize your work and wait for new instructions.";

    while ($self->{turn_count} < $self->{max_turns}) {
        $self->{turn_count}++;
        $self->check_processes();
        $self->check_interrupt();
        if ($self->{turn_count} % 5 == 0) { $self->push_history("user", [{ text => "SYSTEM: This is turn $self->{turn_count} of $self->{max_turns}. Please continue towards your goal." }]); }
        $self->wrap_print('blue', "[Kernel] Turn $self->{turn_count}... Thinking");
        my $response;
        eval { $response = $self->{brain}->chat($self->{history}, $system_instruction, $self->{skills}); };
        if ($@) { warn "[Kernel] Brain Error: $@"; last; }

        # Safety: If model returned NO parts, inject a dummy text so we can continue
        # and not crash the Vertex AI history sequence (user/model/user).
        if (!@{$response->{parts}}) {
            $self->wrap_print('red', "[Kernel] Model returned no parts. Injecting placeholder.");
            push @{$response->{parts}}, { text => "..." };
        }

        $self->push_history("model", $response->{parts});
        my @tool_responses; my $has_text = 0; my $stop_batch = 0;
        foreach my $part (@{$response->{parts}}) {
            $self->check_interrupt();
            last if $stop_batch;
            if ($part->{functionCall}) {
                my $res_content = $self->execute_tool($part->{functionCall});
                push @tool_responses, { functionResponse => { name => $part->{functionCall}->{name}, response => { content => $res_content } } };
                if ($res_content =~ /^(Error:|Usage:|Missing argument|FAILED:)/mi || $res_content =~ /\b(critical error|failed significantly|error occurred during execution)\b/i) {
                    $self->wrap_print('red', "[Kernel] Stop-on-error triggered (Detected failure in output). Cancelling remaining tools.");
                    $res_content .= "

TIP: You likely skipped a step. Check your sequence: Create -> Set-Target -> Add Components -> WRITE CODE -> Build -> Flash.";
                    $stop_batch = 1;
                }
            } elsif ($part->{text}) { $self->wrap_print('yellow', "[Agent] $part->{text}"); $has_text = 1; }
        }
        if (@tool_responses) { $self->push_history("user", \@tool_responses); }
        else {
            my $last_msg = $self->{history}->[-1];
            my $is_system = ($last_msg && $last_msg->{role} eq 'user' && $last_msg->{parts}->[0]->{text} && $last_msg->{parts}->[0]->{text} =~ /^SYSTEM/);
            if ($is_system) { $self->wrap_print('blue', "[Kernel] Processing system notification..."); }
            elsif (!$has_text && @{$response->{parts}} == 0) {
                $self->wrap_print('red', "[Kernel] Empty response detected. Prompting agent to continue...");
                $self->push_history("user", [{ text => "SYSTEM: You provided an empty response. Please proceed with the next step using your tools." }]);
            } else {
                # No tools and no system notifications: Ask the user how to proceed.
                $self->wrap_print('green', "
[Goal Finished] How would you like to proceed?");
                print "  [1] New Goal (Open Editor)
";
                print "  [2] Quick Instruction (Single Line)
";
                print "  [3] Continue (Let agent keep thinking)
";
                print "  [4] Exit
";
                print "Choice [1-4] (default 3): ";
                
                my $choice = <STDIN>;
                chomp($choice) if defined $choice;

                my $input;
                if ($choice eq "1") {
                    $input = $self->get_boxed_input("ENTER NEW GOAL");
                } elsif ($choice eq "2") {
                    print "Instruction: ";
                    $input = <STDIN>;
                    chomp($input) if defined $input;
                } elsif ($choice eq "3" || $choice eq "") {
                    $input = "Please continue.";
                } elsif ($choice eq "4" || !defined $choice) {
                    $input = "exit";
                } else {
                    $input = "Please continue.";
                }
                
                if (defined $input && $input =~ /^\s*exit\s*$/i) {
                    $self->wrap_print('red', "[Kernel] User requested exit.");
                    last;
                }

                if (!defined $input || $input eq "") {
                    $self->push_history("user", [{ text => "Please continue." }]);
                    next;
                }
                
                $self->push_history("user", [{ text => $input }]);
                $self->{turn_count} = 0 if $self->{turn_count} > 500;
            }
        }
        sleep 1;
    }
    $self->cleanup();
    $self->wrap_print('red', "[Kernel] Session ended.");
}

sub cleanup {
    my ($self) = @_;
    foreach my $pid (keys %{$self->{processes}}) {
        if ($self->{processes}->{$pid}->{status} eq "running") {
            $self->wrap_print('yellow', "[Kernel] Cleaning up background process PID $pid...");
            kill 'TERM', $pid;
            $self->{processes}->{$pid}->{status} = "cleaned_up";
        }
    }
}

sub DESTROY {
    my ($self) = @_;
    $self->cleanup();
}

sub execute_tool {
    my ($self, $call) = @_;
    my ($name, $args) = ($call->{name}, $call->{args});
    my $call_sig = $name . encode_json($args);
    if ($self->{last_tool} && $self->{last_tool} eq $call_sig) {
        $self->{repeat_count}++;
        if ($self->{repeat_count} == 4) {
            my $warning = "WARNING: You've tried $name with these exact arguments 4 times. You are likely stuck. Try a different approach.";
            $self->push_history("user", [{ text => $warning }]);
            $self->wrap_print('red', "[Kernel] Loop detected. Sent warning to agent.");
            return "Error: Loop detected. Please change approach.";
        }
    } else { $self->{last_tool} = $call_sig; $self->{repeat_count} = 0; }
    $self->wrap_print('cyan', "[Exec] $name(" . encode_json($args) . ")");
    my $result;
    if (exists $self->{skills}->{$name}) {
        eval { $result = $self->{skills}->{$name}->{code}->($args, $self); };
        $result = "Error executing tool: $@" if $@;
    } else { $result = "Error: Tool $name not found."; }
    $result //= "";
    $self->wrap_print('white', "[Result] $result");
    return $result;
}

sub check_interrupt {
    my ($self) = @_;
    ReadMode('cbreak');
    my $key = ReadKey(-1);
    ReadMode('normal');
    if (defined $key && ord($key) == 27) { # Escape key
        my $input = $self->get_boxed_input("GUIDANCE / INTERRUPT (Ctrl+O to Finish)");
        if ($input) {
            $self->push_history("user", [{ text => "USER INTERRUPT: $input" }]);
            $self->wrap_print('green', "[Kernel] Guidance injected.");
        }
    }
}

sub check_processes {
    my ($self) = @_;
    while ((my $pid = waitpid(-1, WNOHANG)) > 0) {
        if ($self->{processes}->{$pid} && $self->{processes}->{$pid}->{status} eq 'running') {
            my $proc = $self->{processes}->{$pid};
            my $action = $proc->{action};
            $self->wrap_print('', "[Kernel] PID $pid ($action) finished.");
            $proc->{status} = "finished";
            
            my $log_tail = "";
            if ($proc->{log_file} && -f $proc->{log_file}) {
                $log_tail = `tail -n 200 "$proc->{log_file}" 2>/dev/null`;
            }

            my $msg = "SYSTEM: Background process PID $pid ($action) has finished executing.";
            $msg .= "
LAST 200 LINES OF LOG:
$log_tail" if $log_tail;
            $self->push_history("user", [{ text => $msg }]);
        }
    }
    foreach my $pid (keys %{$self->{processes}}) {
        my $proc = $self->{processes}->{$pid};
        next unless $proc->{status} eq "running";

        # Check if the process is actually still alive via kill(0)
        unless (kill(0, $pid)) {
             # Process died but wasn't caught by waitpid yet
             $self->wrap_print('', "[Kernel] PID $pid died unexpectedly.");
             $proc->{status} = "finished";
             next;
        }

        if ($proc->{on_check} && ref $proc->{on_check} eq 'CODE') {
            my ($should_stop, $reason, $is_error) = $proc->{on_check}->($self, $pid, $proc);
            if ($should_stop) {
                $self->wrap_print('yellow', "[Kernel] Auto-stopping PID $pid: $reason");
                kill 'TERM', $pid;
                $proc->{status} = "stopped";
                $proc->{stop_reason} = $reason;
                
                my $log_tail = "";
                if ($proc->{log_file} && -f ($proc->{log_file})) { # Added parens for safety
                    $log_tail = `tail -n 200 "$proc->{log_file}" 2>/dev/null`;
                }

                if ($is_error) {
                    my $msg = "SYSTEM NOTIFICATION: Background monitor (PID $pid) for '$proc->{action}' FAILED because: $reason.";
                    $msg .= "
LAST 200 LINES OF LOG:
$log_tail" if $log_tail;
                    $msg .= "

You MUST analyze the logs and fix the issue.";
                    $self->push_history("user", [{ text => $msg }]);
                } else {
                    my $msg = "SYSTEM NOTIFICATION: Background monitor (PID $pid) for '$proc->{action}' stopped because: $reason.";
                    $msg .= "
LAST 200 LINES OF LOG:
$log_tail" if $log_tail;
                    $msg .= "

The task appears successful. You should now inform the user and ask for the next task.";
                    $self->push_history("user", [{ text => $msg }]);
                }
            }
        }
    }
}

1;
