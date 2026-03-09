# CamelClaw Configuration (Environment Only)
use strict;
use warnings;

# Simple .env loader
if (-f ".env") {
    open my $fh, '<', ".env";
    while (<$fh>) {
        chomp;
        next if /^\s*#/ || /^\s*$/;
        my ($k, $v) = split(/=/, $_, 2);
        $ENV{$k} = $v if $k && defined $v;
    }
    close $fh;
}

my $config = {
    # GCP Vertex AI
    gcp_project_id => $ENV{GCP_PROJECT_ID},
    gcp_region     => $ENV{GCP_REGION},
    
    # Local AI
    local_api_url  => $ENV{LOCAL_API_URL},
    local_token    => $ENV{GEMINI_LOCAL_TOKEN},
    
    # Model Settings
    default_model  => $ENV{GEMINI_MODEL},
    
    # ESP-IDF Paths
    idf_path       => $ENV{IDF_PATH},
    projects_root  => $ENV{PROJECTS_ROOT},
    
    # Logging (Internal paths, but can be overridden)
    session_log    => $ENV{SESSION_LOG} || "logs/session.log",
    monitor_log_prefix => $ENV{MONITOR_LOG_PREFIX} || "logs/monitor_",
};

# Mandatory validation
my @mandatory = qw(GCP_PROJECT_ID GCP_REGION IDF_PATH PROJECTS_ROOT);
my @missing;
foreach my $var (@mandatory) {
    push @missing, $var unless $ENV{$var};
}

if (@missing) {
    print "\n[Config Error] Missing mandatory environment variables:\n";
    print "  - $_\n" for @missing;
    print "\nPlease copy .env.example to .env and fill in these values,\n";
    print "then source your .env file before running CamelClaw.\n\n";
    die "Configuration incomplete. Exiting.\n";
}

$config;
