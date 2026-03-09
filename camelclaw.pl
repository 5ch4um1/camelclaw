#!/usr/bin/perl
use strict;
use warnings;
use lib '/usr/local/lib/x86_64-linux-gnu/perl/5.38.2';
use lib '/usr/local/share/perl/5.38.2';
use lib './lib';
use lib '.';
use Camel::Kernel;
use skills::System;
use skills::ESP32;
use skills::ModifySelf;
use Term::ReadKey;
use Term::ANSIColor;
use Getopt::Long;

# Command line options
my $opt_local_token;
my $opt_model;
GetOptions(
    "local-token=s" => \$opt_local_token,
    "model=s"       => \$opt_model,
);

# Configuration
my $config = do 'config.pl' or die "Could not load config.pl: $!";

# Initialize
my $kernel = Camel::Kernel->new(
    max_turns  => 1000,
    project_id => $config->{gcp_project_id},
    region     => $config->{gcp_region},
    local_url  => $config->{local_api_url},
);
$kernel->{brain}->{local_token} = $opt_local_token if $opt_local_token;
$kernel->{brain}->{local_token} //= $config->{local_token} if $config->{local_token};

my $models = $kernel->{brain}->list_models();

# Startup Menu
my $goal;
my $selected_model;
my @selected_skills;

# If there are remaining arguments, join them as the goal
if (@ARGV) {
    $goal = join(" ", @ARGV);
    $selected_model = $opt_model || $ENV{GEMINI_MODEL} || "gemini-2.0-flash-001";
    @selected_skills = ("System", "ESP32", "ModifySelf");
} else {
    print color('bold blue'), "=== CamelClaw Startup Menu ===\n", color('reset');
    
    # 1. Model Selection
    print color('cyan'), "\nSelect Model:\n", color('reset');
    for my $i (0 .. $#$models) {
        print "  [" . ($i + 1) . "] $models->[$i]\n";
    }
    print "Select [1-" . (@$models) . "] (default 2.0-flash): ";
    my $m_idx = <STDIN>; chomp($m_idx);
    $selected_model = $opt_model || (($m_idx && $m_idx =~ /^\d+$/ && $m_idx <= @$models) ? $models->[$m_idx-1] : "gemini-2.0-flash-001");

    if ($selected_model eq "local" && !$kernel->{brain}->{local_token}) {
        print color('magenta'), "Enter token for local model (or leave empty): ", color('reset');
        my $local_token = <STDIN>; chomp($local_token);
        $kernel->{brain}->{local_token} = $local_token if $local_token;
    }

    # 2. Skill Selection
    my %available_skills = (
        "System"     => "skills::System",
        "ESP32"      => "skills::ESP32",
        "ModifySelf" => "skills::ModifySelf"
    );
    print color('cyan'), "\nSelect Skills (comma separated, e.g., 1,3):\n", color('reset');
    my @s_keys = sort keys %available_skills;
    for my $i (0 .. $#s_keys) {
        print "  [" . ($i + 1) . "] $s_keys[$i]\n";
    }
    print "Select (default all): ";
    my $s_input = <STDIN>; chomp($s_input);
    if ($s_input) {
        my @indices = split(/,/, $s_input);
        for my $idx (@indices) {
            push @selected_skills, $s_keys[$idx-1] if $s_keys[$idx-1];
        }
    } else {
        @selected_skills = @s_keys;
    }

    # 3. Prompt
    $goal = $kernel->get_boxed_input("INITIAL GOAL");
    die "No prompt given. Exiting.\n" unless $goal;
}

# Final Setup
$kernel->{brain}->{model} = $selected_model;
print color('green'), "\n[Main] Using Model: $selected_model\n", color('reset');

foreach my $skill (@selected_skills) {
    my $package = "skills::$skill";
    $kernel->register_skill($skill, $package->register());
}

print color('bold yellow'), "\n[Main] Goal: $goal\n", color('reset');
print color('italic'), "Tip: Press ESC during thinking/execution to interrupt and provide guidance.\n\n", color('reset');

$kernel->loop($goal);
