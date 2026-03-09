package Camel::Brain;
use strict;
use warnings;
use HTTP::Tiny;
use JSON::MaybeXS;

sub new {
    my ($class, %args) = @_;
    
    my $project_id = $args{project_id};
    my $region     = $args{region};
    
    my $self = {
        project_id => $project_id,
        region     => $region,
        model      => $args{model} || "gemini-1.5-flash",
        local_token => $args{local_token} || undef,
        local_url  => $args{local_url},
        http       => HTTP::Tiny->new(timeout => 300),
    };
    
    # Vertex AI Endpoint Format
    $self->{url_base} = "https://$region-aiplatform.googleapis.com/v1/projects/$project_id/locations/$region/publishers/google/models";
    
    return bless $self, $class;
}

sub get_token {
    my ($self) = @_;

    # Use local token if provided and model is local
    return $self->{local_token} if $self->{model} eq "local" && $self->{local_token};

    # Fetch token using gcloud CLI
    my $token = `gcloud auth print-access-token 2>/dev/null`;
    chomp($token);
    die "Error: Could not obtain GCP access token. Is 'gcloud' installed and authenticated?" unless $token;
    return $token;
}

sub list_models {
    my ($self) = @_;
    return [
        "gemini-2.0-flash-001",
        "gemini-2.0-flash-lite-001",
        "local"
    ];
}

sub chat {
    my ($self, $history, $system_instruction, $tools, $retry_count) = @_;

    if ($self->{model} eq "local") {
        return $self->chat_local($history, $system_instruction, $tools);
    }

    $retry_count ||= 0;
    
    my $token = $self->get_token();
    my $url = "$self->{url_base}/$self->{model}:generateContent";
    
    my $payload = {
        contents => $history,
        system_instruction => { parts => [{ text => $system_instruction }] },
    };

    # Add Tool Declarations
    if ($tools && %$tools) {
        $payload->{tools} = [{
            function_declarations => [
                map { {
                    name => $_,
                    description => $tools->{$_}->{description},
                    parameters => $tools->{$_}->{parameters}
                } } keys %$tools
            ]
        }];
    }

    my $res = $self->{http}->post($url, {
        content => encode_json($payload),
        headers => { 
            'Content-Type'  => 'application/json',
            'Authorization' => "Bearer $token"
        }
    });

    if ($res->{status} == 429) {
        if ($retry_count >= 5) {
            die "Maximum retries (5) reached for Vertex AI rate limit (429).";
        }
        
        my $wait = (2 ** $retry_count) * 5 + int(rand(5));
        print "\n[Vertex] Rate limit reached. Attempt: " . ($retry_count + 1) . ". Waiting for $wait seconds...\n";
        sleep $wait;
        return $self->chat($history, $system_instruction, $tools, $retry_count + 1);
    }

    unless ($res->{success}) {
        die "Vertex AI API Error (" . $res->{status} . "): " . $res->{content};
    }

    my $data = decode_json($res->{content});
    
    # Safety check: Sometimes Gemini filters the response or has no content
    unless ($data->{candidates} && @{$data->{candidates}}) {
        return { parts => [{ text => "ERROR: API returned no candidates. This may be due to safety filters or a model error." }] };
    }
    
    my $content = $data->{candidates}[0]{content};
    $content->{parts} ||= [];
    return $content;
}

sub safe_encode {
    my ($data) = @_;
    return ref($data) ? encode_json($data) : ($data // "");
}

sub chat_local {
    my ($self, $history, $system_instruction, $tools, $retry_count) = @_;
    $retry_count ||= 0;
    
    my $url = $self->{local_url};
    
    # 1. Pre-process history: Merge consecutive roles and ensure strict alternation
    my @processed;
    foreach my $turn (@$history) {
        my $role = $turn->{role} eq "model" ? "assistant" : "user";
        if (@processed > 0 && $processed[-1]->{role} eq $role) {
            push @{$processed[-1]->{parts}}, @{$turn->{parts}};
        } else {
            push @processed, { role => $role, parts => [ @{$turn->{parts}} ] };
        }
    }

    # llama-server / Gemma 2 requires starting with 'user'
    if (@processed > 0 && $processed[0]->{role} ne "user") {
        unshift @processed, { role => "user", parts => [{ text => "Please continue." }] };
    }

    # 2. Build Tools Text and System Instructions
    my $tool_list_text = "";
    foreach my $name (sort keys %$tools) {
        my $t = $tools->{$name};
        my @props = sort keys %{$t->{parameters}->{properties}};
        my $example = "$name(" . join(", ", map { "$_=\"...\"" } @props) . ")";
        $tool_list_text .= "- $name: $t->{description}\n  Example: $example\n";
    }

    my $local_system = $system_instruction . 
        "\n\n### AVAILABLE TOOLS ###\n" . $tool_list_text .
        "\n\n### CRITICAL INSTRUCTIONS ###\n" .
        "1. You are a FUNCTION CALLING agent. You generally do not talk; you ACT.\n" .
        "2. To perform a task, you MUST emit a native Tool Call (Function Call) or a text call like tool_name(args).\n" .
        "3. DO NOT use Markdown code blocks for tools. Call tools immediately.\n" .
        "4. ALWAYS use exact parameter names from examples.\n" .
        "5. For esp_write_main_source, 'content' MUST be the FULL implementation.\n" .
        "6. Do not plan in text. Just use the tools in the correct order.\n" .
        "\n### MANDATORY SEQUENCING ###\n" .
        "1. esp_create_project\n" .
        "2. esp_idf_cmd(action='set-target esp32c3')\n" .
        "3. esp_idf_add_component\n" .
        "4. esp_write_main_source (CRITICAL: Do this BEFORE building!)\n" .
        "5. esp_idf_cmd(action='build')\n" .
        "6. esp_idf_cmd(action='flash')\n" .
        "7. esp_idf_cmd(action='monitor')";

    # 3. Convert to OpenAI format with merged system prompt
    my @messages;
    my $system_merged = 0;
    foreach my $turn (@processed) {
        my $role = $turn->{role};
        my $content = "";
        my $tool_calls = undef;
        
        if ($role eq "user" && !$system_merged) {
            $content = "SYSTEM INSTRUCTIONS:\n$local_system\n\nUSER REQUEST:\n";
            $system_merged = 1;
        }

        foreach my $part (@{$turn->{parts}}) {
            if ($part->{text}) {
                $content .= ($content ? "\n" : "") . $part->{text};
            } elsif ($part->{functionCall}) {
                $tool_calls ||= [];
                push @$tool_calls, {
                    id => "call_" . int(rand(1000000)),
                    type => "function",
                    function => { 
                        name => $part->{functionCall}->{name}, 
                        arguments => safe_encode($part->{functionCall}->{args}) 
                    }
                };
            } elsif ($part->{functionResponse}) {
                my $res_str = safe_encode($part->{functionResponse}->{response}->{content});
                $res_str = substr($res_str, 0, 2000) . "... [TRUNCATED]" if length($res_str) > 4000;
                $content .= ($content ? "\n\n" : "") . "TOOL RESULT (" . $part->{functionResponse}->{name} . "):\n" . $res_str;
            }
        }
        
        if ($content ne "" || defined $tool_calls) {
            my $msg = { role => $role };
            $msg->{content} = $content if $content ne "";
            $msg->{tool_calls} = $tool_calls if defined $tool_calls;
            
            # Critical Safety: Gemini/Vertex requires at least one part (content or tool_calls)
            if ($msg->{content} || $msg->{tool_calls}) {
                push @messages, $msg;
            }
        }
    }

    # Ensure we don't have consecutive roles after filtering
    my @final_messages;
    foreach my $m (@messages) {
        if (@final_messages > 0 && $final_messages[-1]->{role} eq $m->{role}) {
            if ($m->{content}) {
                $final_messages[-1]->{content} .= "\n\n" . $m->{content};
            }
            if ($m->{tool_calls}) {
                $final_messages[-1]->{tool_calls} ||= [];
                push @{$final_messages[-1]->{tool_calls}}, @{$m->{tool_calls}};
            }
        } else {
            push @final_messages, $m;
        }
    }

    # Truncate history if it's too long
    if (@final_messages > 30) {
        @final_messages = ($final_messages[0], @final_messages[-28..-1]);
    }

    my @oa_tools;
    foreach my $name (sort keys %$tools) {
        push @oa_tools, {
            type => "function",
            function => { 
                name => $name, 
                description => $tools->{$name}->{description}, 
                parameters => $tools->{$name}->{parameters} 
            }
        };
    }

    my $payload = { model => "local-model", messages => \@messages, stream => 0 };
    $payload->{tools} = \@oa_tools if @oa_tools;

    my $headers = { 'Content-Type' => 'application/json' };
    $headers->{Authorization} = "Bearer $self->{local_token}" if $self->{local_token};

    my $res = $self->{http}->post($url, { content => encode_json($payload), headers => $headers });

    if ($res->{status} == 599 && $retry_count < 2) {
        return $self->chat_local($history, $system_instruction, $tools, $retry_count + 1);
    }

    unless ($res->{success}) {
        die "Local Model API Error (" . $res->{status} . "): " . $res->{content};
    }

    my $data = decode_json($res->{content});
    my $choice = $data->{choices}[0]{message};
    my @res_parts;
    my $text_response = $choice->{content} // "";

    # 4. Robust pseudo-tool parser for hallucinated text calls
    my @patterns = (
        qr/```\s*(\w+):\s*(.*?)\s*```/s,
        qr/Call tool:\s*(\w+)\((.*?)\)/s,
        qr/^(\w+)\((.*?)\)\s*$/m,
        qr/(\w+)\((.*?)\)/s
    );

    foreach my $pattern (@patterns) {
        while ($text_response =~ /$pattern/g) {
            my ($t_name, $t_args_str) = ($1, $2);
            next unless $tools->{$t_name};
            my $args = {};
            if ($t_args_str =~ /\{.*?\}/s) { eval { $args = decode_json($t_args_str); }; }
            if (!$args || !%$args) {
                    while ($t_args_str =~ /(\w+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^,\s\)]+))/g) {
                        my ($k, $val) = ($1, $2 // $3 // $4);
                        $k = "project_dir" if $k eq "project_name";
                        $k = "action" if $k eq "command";
                        $k = "command" if $k eq "action";
                        $k = "component" if $k eq "component_name";

                        if ($val =~ /^\[(.*)/) {
                            my $inner = $1; $inner =~ s/\]$//;
                            my @parts = split(/,/, $inner);
                            foreach my $p (@parts) { $p =~ s/^\s*['"]?|['"]?\s*$//g; }
                            $val = [ grep { $_ ne "" } @parts ];
                        }
                        $args->{$k} = $val;
                    }
            }
            if (!$args || !%$args) {
                my @p_names = keys %{$tools->{$t_name}->{parameters}->{properties}};
                $args->{$p_names[0]} = $t_args_str if @p_names == 1;
            }
            push @res_parts, { functionCall => { name => $t_name, args => $args } } if %$args;
        }
        last if @res_parts;
    }

    push @res_parts, { text => $text_response } if $text_response && $text_response !~ /^\s*$/;
    
    if ($choice->{tool_calls}) {
        foreach my $tc (@{$choice->{tool_calls}}) {
            my $raw_args = $tc->{function}->{arguments};
            my $args = ref $raw_args ? $raw_args : eval { decode_json($raw_args) } || {};
            push @res_parts, { functionCall => { name => $tc->{function}->{name}, args => $args } };
        }
    }
    
    return { parts => \@res_parts };
}

1;
