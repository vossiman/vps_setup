#!/bin/bash

# Enhanced Docker Tools Installation Script for Ubuntu/Linux Mint
# Installs Docker, Docker Compose, and lazydocker with proper error handling and colored output

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to handle errors
handle_error() {
    print_error "$1"
    print_error "Installation failed. Exiting..."
    exit 1
}

# Function to check if running as root
check_sudo() {
    if [[ $EUID -eq 0 ]]; then
        print_warning "Running as root. This is not recommended for Docker installation."
        print_info "Consider running as a regular user with sudo privileges."
    fi
}

# Function to detect OS
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$NAME
        VERSION=$VERSION_ID
    else
        handle_error "Cannot detect OS. This script requires Ubuntu or Linux Mint."
    fi

    if [[ "$OS" != *"Ubuntu"* ]] && [[ "$OS" != *"Linux Mint"* ]]; then
        print_warning "Detected OS: $OS"
        print_warning "This script is designed for Ubuntu or Linux Mint."
        read -p "Do you want to continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Installation cancelled."
            exit 0
        fi
    else
        print_success "Detected compatible OS: $OS $VERSION"
    fi
}

# Function to update package lists
update_packages() {
    print_info "Updating package lists..."
    if sudo apt update; then
        print_success "Package lists updated successfully"
    else
        handle_error "Failed to update package lists"
    fi
}

# Function to install build essentials
install_build_essentials() {
    print_info "Installing build-essential package..."
    if sudo apt install -y build-essential; then
        print_success "build-essential installed successfully"
    else
        handle_error "Failed to install build-essential"
    fi
}

install_python() {
print_info "Installing python3.12-venv package..."
    if sudo apt-get install -y python3.12-venv; then
        print_success "python3.12-venv installed successfully"
    else
        handle_error "Failed to install python3.12-venv"
    fi
}


# Function to install Docker
install_docker() {
    if command_exists docker; then
        print_success "Docker is already installed"
        print_info "Current version: $(docker --version)"
        return 0
    fi

    print_info "Installing Docker..."
    
    # Install prerequisites
    print_info "Installing Docker prerequisites..."
    if sudo apt install -y apt-transport-https ca-certificates curl gnupg lsb-release; then
        print_success "Prerequisites installed successfully"
    else
        handle_error "Failed to install Docker prerequisites"
    fi

    # Add Docker's official GPG key
    print_info "Adding Docker's official GPG key..."
    if curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg; then
        print_success "Docker GPG key added successfully"
    else
        handle_error "Failed to add Docker GPG key"
    fi

    # Add Docker repository
    print_info "Adding Docker repository..."
    if echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null; then
        print_success "Docker repository added successfully"
    else
        handle_error "Failed to add Docker repository"
    fi

    # Update package lists again
    print_info "Updating package lists with Docker repository..."
    if sudo apt update; then
        print_success "Package lists updated successfully"
    else
        handle_error "Failed to update package lists"
    fi

    # Install Docker Engine
    print_info "Installing Docker Engine, CLI, and containerd..."
    if sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        print_success "Docker installed successfully"
    else
        handle_error "Failed to install Docker"
    fi

    # Add current user to docker group
    print_info "Adding current user to docker group..."
    if sudo usermod -aG docker "$USER"; then
        print_success "User added to docker group"
        print_warning "You may need to log out and back in for group changes to take effect"
    else
        print_warning "Failed to add user to docker group"
    fi
}

# Function to install Homebrew
install_homebrew() {
    if command_exists brew; then
        print_success "Homebrew is already installed"
        print_info "Updating Homebrew..."
        if brew update; then
            print_success "Homebrew updated successfully"
        else
            print_warning "Failed to update Homebrew, but continuing..."
        fi
    else
        print_info "Installing Homebrew..."
        if /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
            print_success "Homebrew installed successfully"
            
            # Add Homebrew to PATH for the current session
            if [[ -f "/home/linuxbrew/.linuxbrew/bin/brew" ]]; then
                eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
                print_info "Added Homebrew to PATH for current session"
            fi
        else
            handle_error "Failed to install Homebrew"
        fi
    fi

    # Add Homebrew to user's shell profile permanently
    add_brew_to_profile

    # Verify brew command is available
    if ! command_exists brew; then
        handle_error "Homebrew installation appears to have failed - 'brew' command not found"
    fi
}

# Function to add Homebrew to shell profile
add_brew_to_profile() {
    local brew_shellenv_line='eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"'
    local profile_file="$HOME/.bashrc"
    
    # Check if Homebrew is already in the profile
    if grep -q "brew shellenv" "$profile_file" 2>/dev/null; then
        print_success "Homebrew is already configured in $profile_file"
        return 0
    fi
    
    print_info "Adding Homebrew to $profile_file for permanent PATH configuration..."
    
    # Add Homebrew configuration to .bashrc
    {
        echo ""
        echo "# Added by Docker installation script - Homebrew configuration"
        echo "$brew_shellenv_line"
    } >> "$profile_file"
    
    if [[ $? -eq 0 ]]; then
        print_success "Homebrew added to $profile_file"
        print_info "Homebrew tools will be available in new terminal sessions"
    else
        print_warning "Failed to add Homebrew to $profile_file"
        print_info "You may need to manually add: $brew_shellenv_line"
    fi
}

# Function to install lazydocker
install_lazydocker() {
    if command_exists lazydocker; then
        print_success "lazydocker is already installed"
        print_info "Current version: $(lazydocker --version 2>/dev/null || echo 'Unable to determine version')"
        
        read -p "Do you want to upgrade it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_info "Upgrading lazydocker..."
            if brew upgrade lazydocker; then
                print_success "lazydocker upgraded successfully"
            else
                print_warning "Failed to upgrade lazydocker, but it's still available"
            fi
        fi
    else
        print_info "Installing lazydocker..."
        if brew install lazydocker; then
            print_success "lazydocker installed successfully"
        else
            handle_error "Failed to install lazydocker"
        fi
    fi
}

# Function to verify installations
verify_installations() {
    print_info "Verifying installations..."
    echo
    
    if command_exists docker; then
        print_success "✓ Docker is working ($(docker --version))"
        
        # Test Docker without sudo (may fail if user needs to log out/in)
        if docker ps >/dev/null 2>&1; then
            print_success "✓ Docker can run without sudo"
        else
            print_warning "! Docker requires sudo (you may need to log out and back in)"
        fi

        # Check Docker Compose
        if docker compose version >/dev/null 2>&1; then
            print_success "✓ Docker Compose is working ($(docker compose version --short))"
        else
            print_warning "! Docker Compose verification failed"
        fi
    else
        print_error "✗ Docker verification failed"
    fi

    if command_exists brew; then
        print_success "✓ Homebrew is working ($(brew --version | head -n1))"
    else
        print_error "✗ Homebrew verification failed"
    fi

    if command_exists lazydocker; then
        print_success "✓ lazydocker is working ($(lazydocker --version 2>/dev/null || echo 'version check failed'))"
    else
        print_error "✗ lazydocker verification failed"
    fi
}

# Main installation function
main() {
    print_info "Starting Docker tools installation for Ubuntu/Linux Mint..."
    echo

    # Preliminary checks
    check_sudo
    detect_os
    echo

    # Update package lists
    update_packages
    echo

    # Install build essentials
    install_build_essentials
    echo
	
	# Install python3.12-venv
	install_python
	echo

    # Install Docker
    install_docker
    echo

    # Install Homebrew
    install_homebrew
    echo

    # Install lazydocker
    install_lazydocker
    echo

    # Verify installations
    verify_installations
    echo

    print_success "Installation completed!"
    print_info "You can now use:"
    print_info "  • 'docker' to manage containers"
    print_info "  • 'docker compose' to manage multi-container applications"
    print_info "  • 'lazydocker' to manage Docker with a terminal UI"
    print_info "  • 'brew' to install additional development tools"
	print_info "  • also python3.12-venv is installed for your convenience"
    echo
    print_warning "If Docker commands require sudo, log out and back in to apply group changes."
    print_info "To use Homebrew tools immediately, run: source ~/.bashrc"
    print_info "Or start a new terminal session."
    echo
    print_warning "If Docker commands require sudo, log out and back in to apply group changes."
}

# Script execution starts here
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi