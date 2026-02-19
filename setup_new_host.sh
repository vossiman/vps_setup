#!/bin/bash

# Enhanced New Host Setup Script
# Creates user, configures SSH with proper security settings
# Run with: sudo ./setup_new_host.sh

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print colored messages
print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

# Function to handle errors
handle_error() {
    print_error "$1"
    print_error "Setup failed. Exiting..."
    exit 1
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        handle_error "This script must be run as root (use sudo)"
    fi
}

# Function to validate SSH public key format
validate_ssh_key() {
    local key="$1"
    
    # Basic validation - should start with ssh-rsa, ssh-ed25519, etc.
    if [[ ! "$key" =~ ^ssh-(rsa|dss|ed25519|ecdsa) ]]; then
        return 1
    fi
    
    # Check if it has the basic structure (type key comment)
    local parts_count=$(echo "$key" | wc -w)
    if [[ $parts_count -lt 2 ]]; then
        return 1
    fi
    
    return 0
}

# Function to create user
create_user() {
    local username="$1"
    
    print_step "Creating user '$username'..."
    
    if id "$username" &>/dev/null; then
        print_success "User '$username' already exists"
        return 0
    fi
    
    # Create user with home directory
    if adduser --disabled-password --gecos "" "$username"; then
        print_success "User '$username' created successfully"
    else
        handle_error "Failed to create user '$username'"
    fi
    
    # Set password for the user
    print_step "Setting password for user '$username'..."
    echo
    print_info "Enter a password for user '$username' (for SSH access if needed):"
    if passwd "$username"; then
        print_success "Password set for user '$username'"
    else
        print_warning "Failed to set password - user created but may need manual password setup"
    fi
}

# Function to add user to sudo group
add_to_sudo() {
    local username="$1"
    
    print_step "Adding user '$username' to sudo group..."
    
    if usermod -aG sudo "$username"; then
        print_success "User '$username' added to sudo group"
    else
        handle_error "Failed to add user '$username' to sudo group"
    fi
    
    # Verify user is in sudo group
    if groups "$username" | grep -q "\bsudo\b"; then
        print_success "Verified: User '$username' is in sudo group"
    else
        handle_error "Verification failed: User '$username' not in sudo group"
    fi
}

# Function to get and validate SSH public key
get_ssh_key() {
    local ssh_key=""
    
    echo >&2
    echo "═══════════════════════════════════════════════════════════════════════════════" >&2
    print_info "PURPOSE: Enable passwordless SSH login to this server" >&2
    print_info "KEY TYPE: Paste your SSH PUBLIC KEY (from .pub file, NOT your private key)" >&2
    echo "═══════════════════════════════════════════════════════════════════════════════" >&2
    echo >&2
    print_step "👉 PASTE YOUR SSH PUBLIC KEY NOW (then press Enter):" >&2
    echo >&2
    printf "> " >&2
    read -r ssh_key
    
    if [[ -z "$ssh_key" ]]; then
        echo >&2
        print_error "No SSH key provided - you pressed Enter without pasting anything" >&2
        print_warning "Please run the script again and paste your SSH public key when prompted" >&2
        handle_error "No SSH key provided"
    fi
    
    # Validate SSH key format
    if validate_ssh_key "$ssh_key"; then
        print_success "SSH key format appears valid" >&2
        echo "$ssh_key"
    else
        print_error "Invalid SSH key format" >&2
        print_info "SSH keys should start with: ssh-rsa, ssh-ed25519, ssh-ecdsa, or ssh-dss" >&2
        handle_error "Please provide a valid SSH public key"
    fi
}

# Function to setup SSH directory and key
setup_ssh_key() {
    local username="$1"
    local ssh_key="$2"
    local home_dir="/home/$username"
    local ssh_dir="$home_dir/.ssh"
    local auth_keys="$ssh_dir/authorized_keys"
    
    print_step "Setting up SSH directory and authorized_keys..."
    
    # Create .ssh directory
    if sudo -u "$username" mkdir -p "$ssh_dir"; then
        print_success "Created .ssh directory"
    else
        handle_error "Failed to create .ssh directory"
    fi
    
    # Set correct permissions on .ssh directory
    if sudo -u "$username" chmod 700 "$ssh_dir"; then
        print_success "Set permissions on .ssh directory (700)"
    else
        handle_error "Failed to set permissions on .ssh directory"
    fi
    
    # Create authorized_keys file
    if sudo -u "$username" touch "$auth_keys"; then
        print_success "Created authorized_keys file"
    else
        handle_error "Failed to create authorized_keys file"
    fi
    
    # Set correct permissions on authorized_keys
    if sudo -u "$username" chmod 600 "$auth_keys"; then
        print_success "Set permissions on authorized_keys file (600)"
    else
        handle_error "Failed to set permissions on authorized_keys file"
    fi
    
    # Add SSH public key
    if echo "$ssh_key" | sudo -u "$username" tee "$auth_keys" > /dev/null; then
        print_success "Added SSH public key to authorized_keys"
    else
        handle_error "Failed to add SSH key to authorized_keys"
    fi
    
    # Verify the key was added correctly
    if sudo -u "$username" cat "$auth_keys" | grep -q "ssh-"; then
        print_success "Verified: SSH key added successfully"
    else
        handle_error "Verification failed: SSH key not found in authorized_keys"
    fi
}

# Function to backup SSH configuration
backup_ssh_config() {
    local config_file="/etc/ssh/sshd_config"
    local backup_file="/etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)"
    
    print_step "Backing up SSH configuration..."
    
    if cp "$config_file" "$backup_file"; then
        print_success "SSH config backed up to: $backup_file"
        echo "$backup_file"
    else
        handle_error "Failed to backup SSH configuration"
    fi
}

# Function to handle sshd_config.d directory (cloud-init, Hetzner, etc.)
handle_sshd_config_d() {
    local config_dir="/etc/ssh/sshd_config.d"
    local backup_dir="/etc/ssh/sshd_config.d.backup.$(date +%Y%m%d_%H%M%S)"
    
    if [[ ! -d "$config_dir" ]]; then
        print_info "No sshd_config.d directory found, skipping"
        return 0
    fi
    
    print_step "Checking sshd_config.d directory for conflicting settings..."
    
    # Backup the entire directory
    if cp -r "$config_dir" "$backup_dir" 2>/dev/null; then
        print_success "Backed up sshd_config.d to: $backup_dir"
    fi
    
    # Find and fix files with conflicting settings
    local fixed_count=0
    while IFS= read -r -d '' file; do
        if [[ -f "$file" ]]; then
            local filename=$(basename "$file")
            local has_conflicts=false
            
            # Check for conflicting settings and remove them
            local conflicting_settings=(
                "PasswordAuthentication"
                "PubkeyAuthentication"
                "PermitRootLogin"
            )
            
            for setting in "${conflicting_settings[@]}"; do
                if grep -qE "^[[:space:]]*$setting" "$file" 2>/dev/null; then
                    if [[ "$has_conflicts" == false ]]; then
                        print_warning "Found conflicting settings in $filename, removing them"
                        has_conflicts=true
                        fixed_count=$((fixed_count + 1))
                    fi
                    sed -i "/^[[:space:]]*$setting/d" "$file"
                fi
            done
        fi
    done < <(find "$config_dir" -type f -name "*.conf" -print0 2>/dev/null)
    
    if [[ $fixed_count -gt 0 ]]; then
        print_success "Fixed $fixed_count conflicting file(s) in sshd_config.d"
    else
        print_info "No conflicting settings found in sshd_config.d"
    fi
}

# Function to configure SSH settings
configure_ssh() {
    local config_file="/etc/ssh/sshd_config"
    
    print_step "Configuring SSH security settings..."
    
    # Function to set SSH config value
    set_ssh_config() {
        local setting="$1"
        local value="$2"
        
        print_info "Setting $setting to $value"
        
        # Remove any existing lines (commented or not)
        sed -i "/^#*$setting/d" "$config_file"
        
        # Add the new setting
        echo "$setting $value" >> "$config_file"
    }
    
    # Configure SSH settings for security
    set_ssh_config "PasswordAuthentication" "no"
    set_ssh_config "PubkeyAuthentication" "yes"
    set_ssh_config "PermitRootLogin" "no"
    set_ssh_config "ChallengeResponseAuthentication" "no"
    set_ssh_config "UsePAM" "yes"
    set_ssh_config "X11Forwarding" "no"
    set_ssh_config "PrintMotd" "no"
    set_ssh_config "AcceptEnv" "LANG LC_*"
    set_ssh_config "Subsystem" "sftp /usr/lib/openssh/sftp-server"
    
    print_success "SSH security settings configured"
}

# Function to test SSH configuration
test_ssh_config() {
    print_step "Testing SSH configuration..."
    
    if sshd -t; then
        print_success "SSH configuration test passed"
    else
        handle_error "SSH configuration test failed - check syntax"
    fi
}

# Function to restart SSH service
restart_ssh() {
    print_step "Restarting SSH service..."
    
    if systemctl restart ssh; then
        print_success "SSH service restarted successfully"
    else
        handle_error "Failed to restart SSH service"
    fi
    
    # Wait a moment for service to start
    sleep 2
    
    # Verify SSH service is running
    if systemctl is-active --quiet ssh; then
        print_success "SSH service is running"
    else
        handle_error "SSH service is not running properly"
    fi
}

# Function to display final instructions
show_final_instructions() {
    local username="$1"
    local server_ip=$(hostname -I | awk '{print $1}')
    
    echo
    echo "=================================="
    print_success "🎉 Setup completed successfully!"
    echo "=================================="
    echo
    print_info "SSH Configuration Summary:"
    print_info "  • Password authentication: DISABLED"
    print_info "  • Public key authentication: ENABLED"
    print_info "  • Root login: DISABLED"
    print_info "  • User '$username' created with sudo privileges"
    echo
    print_info "Connection Details:"
    print_info "  • Username: $username"
    print_info "  • Server IP: $server_ip"
    print_info "  • SSH Command: ssh $username@$server_ip"
    echo
    print_warning "🚨 IMPORTANT SECURITY NOTICE:"
    print_warning "  • Test the new SSH connection in a separate terminal"
    print_warning "  • Do NOT close this session until you verify access"
    print_warning "  • Keep your SSH private key secure"
    echo
    print_info "If you get locked out, you can restore SSH config from backup:"
    print_info "  sudo cp /etc/ssh/sshd_config.backup.* /etc/ssh/sshd_config"
    print_info "  sudo systemctl restart ssh"
    echo
}

# Main function
main() {
    local username=""

    echo
    print_info "🚀 Starting Enhanced New Host Setup..."
    print_info "This script will create a user and configure secure SSH access"
    echo
    
    # Preliminary checks
    check_root

    # Get target username
    while true; do
        read -r -p "Enter username to create/configure [vossi]: " username
        username="${username:-vossi}"

        if [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            break
        fi

        print_warning "Invalid username. Use lowercase letters, numbers, underscores, or hyphens."
    done
    print_info "Using username: $username"
    echo
    
    # Create user
    create_user "$username"
    echo
    
    # Add user to sudo group
    add_to_sudo "$username"
    echo
    
    # Get SSH public key
    ssh_public_key=$(get_ssh_key)
    echo
    
    # Setup SSH key
    setup_ssh_key "$username" "$ssh_public_key"
    echo
    
    # Backup SSH config
    backup_file=$(backup_ssh_config)
    echo
    
    # Handle sshd_config.d directory (cloud-init, Hetzner, etc.)
    handle_sshd_config_d
    echo
    
    # Configure SSH
    configure_ssh
    echo
    
    # Test SSH configuration
    test_ssh_config
    echo
    
    # Restart SSH service
    restart_ssh
    echo
    
    # Show final instructions
    show_final_instructions "$username"
}

# Script execution starts here
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
