package skills::ESP32;
use strict;
use warnings;
use POSIX ":sys_wait_h";
use IO::Pty;
use IO::Select;
use File::Slurper qw(read_text write_text);

# Load Configuration
my $config = do 'config.pl' or die "Could not load config.pl: $!";
my $IDF_PATH = $config->{idf_path};
my $PROJECTS_ROOT = $config->{projects_root};

sub _resolve_path {
    my ($path) = @_;
    return $path if !$path || $path =~ /^\//; # Absolute path
    $path =~ s/^projects\///; # Strip 'projects/' if the model added it
    return "$PROJECTS_ROOT/$path";
}

sub register {
    return {
        'esp_idf_cmd' => {
            description => "Execute an idf.py command (build, flash, monitor, etc.). CRITICAL: You MUST call 'esp_write_main_source' BEFORE calling 'build'. NEVER build an empty project. " .
                           "IMPORTANT: This tool ALREADY sources the environment and manages directories. NEVER use 'run_shell' for idf.py. " .
                           "For 'monitor', use is_background=true and provide 'stop_patterns' based on expected firmware output (e.g., ['LED orange']).",
            parameters => {
                type => "object",
                properties => {
                    action => { type => "string", description => "The idf.py action (e.g., 'build', 'flash', 'set-target esp32c3')." },
                    project_dir => { type => "string", description => "FULL PATH to the project directory." },
                    is_background => { type => "boolean", description => "Set to true for 'monitor'." },
                    stop_patterns => { 
                        type => "array", 
                        items => { type => "string" },
                        description => "Stop monitoring if any of these patterns appear in logs."
                    }
                },
                required => ["action", "project_dir"]
            },
            code => \&run_idf_cmd
        },
        'esp_create_project' => {
            description => "Create a new ESP-IDF project.",
            parameters => {
                type => "object",
                properties => {
                    name => { type => "string", description => "The name of the project." }
                },
                required => ["name"]
            },
            code => sub {
                my ($args) = @_;
                my $name = $args->{name};
                mkdir $PROJECTS_ROOT unless -d $PROJECTS_ROOT;
                
                my $full_path = "$PROJECTS_ROOT/$name";
                if (-d $full_path) {
                    return "Success: Project '$name' already exists at $full_path. Proceeding.";
                }

                my $cmd = "cd $PROJECTS_ROOT && bash -c '. $IDF_PATH/export.sh && idf.py create-project $name'";
                my $out = `$cmd 2>&1`;
                
                if (-d "$full_path/main") {
                    my @files = glob("$full_path/main/*.c");
                    if (@files && $files[0] !~ /main\.c$/) {
                        my $old_file = $files[0];
                        rename $old_file, "$full_path/main/main.c";
                        if (-f "$full_path/main/CMakeLists.txt") {
                            my $cmake = read_text("$full_path/main/CMakeLists.txt");
                            my ($name_only) = $old_file =~ m|/([^/]+)\.c$|;
                            $cmake =~ s/\Q$name_only.c\E/main.c/g;
                            write_text("$full_path/main/CMakeLists.txt", $cmake);
                        }
                    }
                }
                return "Project created at $full_path\n\n$out";
            }
        },
        'esp_write_main_source' => {
            description => "Write the main application source (main/main.c) and CMakeLists.txt. " .
                           "MANDATORY: You MUST call this tool before 'build'. " .
                           "For the onboard LED, use GPIO 10 and the 'led_strip_new_rmt_device' API from 'led_strip.h'.",
            parameters => {
                type => "object",
                properties => {
                    project_dir => { type => "string" },
                    content => { type => "string" },
                    additional_srcs => { type => "array", items => { type => "string" } }
                },
                required => ["project_dir", "content"]
            },
            code => sub {
                my ($args) = @_;
                my $dir = _resolve_path($args->{project_dir});
                my $main_dir = "$dir/main";
                mkdir $main_dir unless -d $main_dir;
                unlink glob("$main_dir/*.c") if -d $main_dir;

                my $code = $args->{content};
                $code = "#include \"esp_log.h\"\n" . $code unless $code =~ /esp_log\.h/;
                if ($code !~ /APP_START/) {
                    $code =~ s/(app_main\s*\([^)]*\)\s*\{)/$1\n    ESP_LOGI("CAMEL", "APP_START");/;
                }

                write_text("$main_dir/main.c", $code);
                my @srcs = ("main.c", @{$args->{additional_srcs} || []});
                my $src_list = join(" ", map { "\"$_\"" } @srcs);
                write_text("$main_dir/CMakeLists.txt", "idf_component_register(SRCS $src_list\n                    INCLUDE_DIRS \".\")\n");

                open my $lock, '>', "$dir/.source_written";
                print $lock time();
                close $lock;

                return "Successfully wrote main.c and registered components.";
            }
        },
        'esp_idf_add_component' => {
            description => "Add a component to the project.",
            parameters => {
                type => "object",
                properties => {
                    component => { type => "string" },
                    project_dir => { type => "string" }
                },
                required => ["component", "project_dir"]
            },
            code => \&add_idf_component
        },
        'esp_check_log' => {
            description => "Read the latest monitor logs.",
            parameters => {
                type => "object",
                properties => { lines => { type => "integer" } }
            },
            code => sub {
                my ($args) = @_;
                my $lines = $args->{lines} || 50;
                my @logs = sort { (stat($b))[9] <=> (stat($a))[9] } glob("logs/monitor*.log");
                return "Error: No monitor log found." unless @logs;
                my $latest = $logs[0];
                return "[Log: $latest]\n" . `tail -n $lines "$latest" 2>/dev/null`;
            }
        },
        'esp_stop_monitor' => {
            description => "Stop a background monitor process.",
            parameters => {
                type => "object",
                properties => { pid => { type => "integer" } },
                required => ["pid"]
            },
            code => sub {
                my ($args, $kernel) = @_;
                my $pid = $args->{pid};
                if ($kernel->{processes}->{$pid}) {
                    kill 'TERM', $pid;
                    $kernel->{processes}->{$pid}->{status} = "manual_stopped";
                    return "Stopped PID $pid.";
                }
                return "PID $pid not found.";
            }
        }
    };
}

sub run_idf_cmd {
    my ($args, $kernel) = @_;
    my $action = $args->{action};
    my $dir = _resolve_path($args->{project_dir} || ".");
    
    if ($action =~ /^(build|flash)/) {
        unless (-f "$dir/main/main.c" && -f "$dir/.source_written") {
            return "Error: You MUST call esp_write_main_source before building/flashing.";
        }
    }

    my $cmd_str = "cd $dir && bash -c '. $IDF_PATH/export.sh && idf.py $action'";
    
    if ($args->{is_background} && $action =~ /monitor/) {
        # Optimization: Directly call the monitor script to avoid slow idf.py environment checks in PTY
        my $python = "$ENV{HOME}/.espressif/python_env/idf5.5_py3.12_env/bin/python";
        my $monitor_script = "$IDF_PATH/tools/idf_monitor.py";
        # We need to find the ELF file for decoding. It's usually in build/<project_name>.elf
        my ($project_name) = $dir =~ m|/([^/]+)$|;
        my $elf_file = "$dir/build/$project_name.elf";
        
        $cmd_str = "cd $dir && $python $monitor_script --toolchain-prefix riscv32-esp-elf- --target esp32c3 $elf_file";
    }

    if ($args->{is_background}) {
        my $pty = IO::Pty->new();
        my $pid = fork();
        die "Fork failed: $!" unless defined $pid;

        if ($pid == 0) {
            $pty->make_slave_controlling_terminal();
            my $slave = $pty->slave();
            open STDIN, "<&", $slave->fileno() or die $!;
            open STDOUT, ">&", $slave->fileno() or die $!;
            open STDERR, ">&", $slave->fileno() or die $!;
            close $slave;
            exec("bash", "-c", $cmd_str);
            exit;
        } else {
            $pty->close_slave();
            $pty->set_raw();
            mkdir "logs" unless -d "logs";
            my $log_file = "logs/monitor_$pid.log";
            
            my $proc_info = { 
                action => $action, 
                status => "running", 
                log_file => $log_file, 
                stop_patterns => $args->{stop_patterns} || [],
                pty => $pty,
                last_offset => 0,
                reboot_count => 0,
            };

            $proc_info->{on_check} = sub {
                my ($kernel, $pid, $proc) = @_;
                my $sel = IO::Select->new($proc->{pty});
                
                # Read from PTY and append to log
                if ($sel->can_read(0.01)) {
                    my $buf;
                    my $bytes = sysread($proc->{pty}, $buf, 4096);
                    if ($bytes) {
                        # Strip ANSI if needed, but for now just log
                        open my $lfh, '>>', $proc->{log_file};
                        print $lfh $buf;
                        close $lfh;
                    }
                }

                return (0, "") unless -f $proc->{log_file};
                
                # Buffered log scanning: only read from last_offset
                open my $fh, '<', $proc->{log_file} or return (0, "");
                seek($fh, $proc->{last_offset}, 0);
                
                my $found_success = 0;
                my $success_pattern = "";
                my $found_error = 0;
                my $error_msg = "";
                
                while (my $line = <$fh>) {
                    # Reboot Detection
                    if ($line =~ /Rebooting\.\.\./i) {
                        $proc->{reboot_count}++;
                        if ($proc->{reboot_count} >= 3) {
                            $found_error = 1;
                            $error_msg = "Reboot loop detected (3+ reboots). Check for driver conflicts or illegal instructions.";
                            last;
                        }
                    }

                    # Success Patterns
                    foreach my $p (@{$proc->{stop_patterns}}) {
                        if ($line =~ /$p/i) {
                            $found_success = 1;
                            $success_pattern = $p;
                            last;
                        }
                    }

                    # Error Patterns
                    if ($line =~ /(Guru Meditation|Panic|abort\(\))/i) {
                        $found_error = 1;
                        $error_msg = $line;
                        last;
                    }
                }
                $proc->{last_offset} = tell($fh);
                close $fh;

                return (1, "Pattern $success_pattern matched", 0) if $found_success;
                return (1, "Error: $error_msg", 1) if $found_error;
                return (0, "");
            };

            $kernel->{processes}->{$pid} = $proc_info;
            return "Started '$action' in background (PID: $pid) with PTY. Logs: $log_file";
        }
    } else {
        my $res = `bash -c "$cmd_str" 2>&1`;
        if ($res =~ /fatal error: (.*?): No such file/) { $res .= "\n(Hint: Missing header: $1)"; }
        elsif ($res =~ /ninja: build stopped/) { $res .= "\n(Hint: Build FAILED)"; }
        return $res;
    }
}

sub add_idf_component {
    my ($args) = @_;
    my $dir = _resolve_path($args->{project_dir});
    my $comp = $args->{component};
    return "Success: Component '$comp' is standard." if $comp =~ /^(driver|esp_log|freertos)$/i;
    my $cmd = "cd $dir && bash -c '. $IDF_PATH/export.sh && idf.py add-dependency \"$comp\"'";
    return `$cmd 2>&1`;
}

1;
