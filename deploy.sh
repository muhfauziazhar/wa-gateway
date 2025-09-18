#!/bin/bash

# WhatsApp Gateway Deployment Script for DigitalOcean Droplet
# Compatible with existing n8n setup

set -e

echo "🚀 Starting WhatsApp Gateway deployment on DigitalOcean..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -eq 0 ]]; then
   print_error "This script should not be run as root. Please run as regular user with sudo privileges."
   exit 1
fi

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check system requirements
check_system() {
    print_status "Checking system requirements..."
    
    # Check available memory
    AVAILABLE_MEM=$(free -m | awk 'NR==2{printf "%.0f", $7}')
    if [ "$AVAILABLE_MEM" -lt 512 ]; then
        print_warning "Available memory is ${AVAILABLE_MEM}MB. Recommended minimum is 512MB."
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # Check disk space
    AVAILABLE_DISK=$(df / | awk 'NR==2 {print $4}')
    if [ "$AVAILABLE_DISK" -lt 2097152 ]; then # 2GB in KB
        print_warning "Available disk space might be low. Please ensure at least 2GB free space."
    fi
    
    print_success "System requirements check passed"
}

# Install required packages
install_requirements() {
    print_status "Installing required packages..."
    
    # Update package list
    sudo apt update
    
    # Install required packages if not exists
    PACKAGES="git curl wget htop"
    for pkg in $PACKAGES; do
        if ! command_exists $pkg; then
            print_status "Installing $pkg..."
            sudo apt install -y $pkg
        fi
    done
    
    # Check if Docker is installed
    if ! command_exists docker; then
        print_status "Installing Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        sudo usermod -aG docker $USER
        rm get-docker.sh
        print_success "Docker installed. Please log out and log back in to use Docker without sudo."
    fi
    
    # Check if Docker Compose is installed
    if ! command_exists docker-compose; then
        print_status "Installing Docker Compose..."
        sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
    fi
    
    print_success "All requirements installed"
}

# Setup project directory
setup_project() {
    print_status "Setting up project directory..."
    
    # Create project directory
    PROJECT_DIR="/opt/wa-gateway"
    
    if [ -d "$PROJECT_DIR" ]; then
        print_warning "Project directory already exists. Backing up..."
        sudo mv "$PROJECT_DIR" "${PROJECT_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # Clone repository
    print_status "Cloning WhatsApp Gateway repository..."
    sudo mkdir -p /opt
    sudo git clone https://github.com/muhfauziazhar/wa-gateway.git "$PROJECT_DIR"
    sudo chown -R $USER:$USER "$PROJECT_DIR"
    
    # Create required directories
    sudo mkdir -p "$PROJECT_DIR/wa_credentials" "$PROJECT_DIR/media" "$PROJECT_DIR/logs"
    sudo chown -R 1001:1001 "$PROJECT_DIR/wa_credentials" "$PROJECT_DIR/media"
    
    print_success "Project directory setup completed"
}

# Configure environment
configure_environment() {
    print_status "Configuring environment..."
    
    cd /opt/wa-gateway
    
    # Copy environment file
    if [ ! -f .env ]; then
        cp .env.docker .env
        
        # Generate random API key
        API_KEY=$(openssl rand -base64 32)
        sed -i "s/your-super-secure-api-key-here/$API_KEY/" .env
        
        print_success "Environment file created with generated API key"
        print_warning "Your API Key: $API_KEY"
        print_warning "Save this key! You'll need it to access the API."
    fi
    
    # Ask for domain configuration
    echo ""
    read -p "Enter your domain for WhatsApp Gateway (e.g., wa.yourdomain.com): " WA_DOMAIN
    read -p "Enter your webhook URL (optional, press enter to skip): " WEBHOOK_URL
    
    if [ ! -z "$WEBHOOK_URL" ]; then
        sed -i "s|# WEBHOOK_BASE_URL=https://your-webhook-domain.com|WEBHOOK_BASE_URL=$WEBHOOK_URL|" .env
    fi
    
    print_success "Environment configuration completed"
}

# Setup Nginx reverse proxy
setup_nginx() {
    print_status "Setting up Nginx reverse proxy..."
    
    # Install Nginx if not exists
    if ! command_exists nginx; then
        sudo apt install -y nginx
    fi
    
    # Backup existing nginx config if exists
    if [ -f /etc/nginx/sites-enabled/default ]; then
        sudo mv /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/default.backup
    fi
    
    # Copy our nginx config
    sudo cp /opt/wa-gateway/nginx-config.conf /etc/nginx/sites-available/wa-gateway
    
    # Update domain in nginx config
    sudo sed -i "s/wa.yourdomain.com/$WA_DOMAIN/g" /etc/nginx/sites-available/wa-gateway
    
    # Enable site
    sudo ln -sf /etc/nginx/sites-available/wa-gateway /etc/nginx/sites-enabled/
    
    # Test nginx config
    sudo nginx -t
    
    # Reload nginx
    sudo systemctl reload nginx
    
    print_success "Nginx configuration completed"
}

# Deploy application
deploy_application() {
    print_status "Deploying WhatsApp Gateway application..."
    
    cd /opt/wa-gateway
    
    # Build and start containers
    docker-compose up -d --build
    
    # Wait for container to be healthy
    print_status "Waiting for application to start..."
    sleep 30
    
    # Check container status
    if docker-compose ps | grep -q "Up"; then
        print_success "Application deployed successfully!"
    else
        print_error "Application deployment failed. Check logs with: docker-compose logs"
        exit 1
    fi
}

# Setup SSL certificate
setup_ssl() {
    print_status "Setting up SSL certificate..."
    
    # Install Certbot if not exists
    if ! command_exists certbot; then
        sudo apt install -y certbot python3-certbot-nginx
    fi
    
    # Get SSL certificate
    sudo certbot --nginx -d $WA_DOMAIN --non-interactive --agree-tos --email admin@$WA_DOMAIN
    
    print_success "SSL certificate configured"
}

# Setup firewall
setup_firewall() {
    print_status "Configuring firewall..."
    
    # Enable UFW if not enabled
    if ! sudo ufw status | grep -q "Status: active"; then
        sudo ufw --force enable
    fi
    
    # Allow necessary ports
    sudo ufw allow ssh
    sudo ufw allow 80
    sudo ufw allow 443
    
    # Allow n8n port if needed (assuming it's on 5678)
    sudo ufw allow 5678
    
    print_success "Firewall configured"
}

# Setup monitoring
setup_monitoring() {
    print_status "Setting up monitoring and maintenance..."
    
    # Create backup script
    cat > /opt/wa-gateway/backup.sh << 'EOF'
#!/bin/bash
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/opt/wa-gateway/backups"
mkdir -p $BACKUP_DIR

# Backup credentials and media
tar -czf $BACKUP_DIR/wa-gateway-$DATE.tar.gz wa_credentials/ media/ .env

# Keep only last 7 backups
find $BACKUP_DIR -name "wa-gateway-*.tar.gz" -mtime +7 -delete

echo "Backup completed: wa-gateway-$DATE.tar.gz"
EOF
    
    chmod +x /opt/wa-gateway/backup.sh
    
    # Add to crontab (daily backup at 2 AM)
    (crontab -l 2>/dev/null; echo "0 2 * * * /opt/wa-gateway/backup.sh") | crontab -
    
    # Create monitoring script
    cat > /opt/wa-gateway/monitor.sh << 'EOF'
#!/bin/bash
cd /opt/wa-gateway

# Check if container is running
if ! docker-compose ps | grep -q "Up"; then
    echo "$(date): Container not running, attempting restart..." >> logs/monitor.log
    docker-compose up -d
fi

# Check memory usage
MEMORY_USAGE=$(docker stats --no-stream --format "{{.MemPerc}}" wa-gateway | sed 's/%//')
if (( $(echo "$MEMORY_USAGE > 80" | bc -l) )); then
    echo "$(date): High memory usage: ${MEMORY_USAGE}%" >> logs/monitor.log
fi
EOF
    
    chmod +x /opt/wa-gateway/monitor.sh
    
    # Add monitoring to crontab (every 5 minutes)
    (crontab -l 2>/dev/null; echo "*/5 * * * * /opt/wa-gateway/monitor.sh") | crontab -
    
    print_success "Monitoring setup completed"
}

# Final status check
final_check() {
    print_status "Performing final status check..."
    
    # Check container status
    cd /opt/wa-gateway
    docker-compose ps
    
    # Check application health
    sleep 10
    if curl -s http://localhost:5001/health > /dev/null; then
        print_success "Application is healthy and responding"
    else
        print_warning "Application health check failed. Check logs with: docker-compose logs"
    fi
    
    # Display access information
    echo ""
    echo "🎉 Deployment completed successfully!"
    echo ""
    echo "📋 Access Information:"
    echo "   Application URL: https://$WA_DOMAIN"
    echo "   API Key: $(grep WA_GATEWAY_KEY .env | cut -d'=' -f2)"
    echo "   Local Access: http://localhost:5001"
    echo ""
    echo "📚 Useful Commands:"
    echo "   View logs: docker-compose logs -f"
    echo "   Restart: docker-compose restart"
    echo "   Stop: docker-compose down"
    echo "   Update: git pull && docker-compose up -d --build"
    echo ""
    echo "📁 Important Directories:"
    echo "   Project: /opt/wa-gateway"
    echo "   Credentials: /opt/wa-gateway/wa_credentials"
    echo "   Media: /opt/wa-gateway/media"
    echo "   Logs: /opt/wa-gateway/logs"
    echo ""
    echo "🔧 Next Steps:"
    echo "   1. Test API endpoints"
    echo "   2. Create WhatsApp session"
    echo "   3. Configure webhooks (if needed)"
    echo "   4. Setup monitoring alerts"
}

# Main execution
main() {
    echo "🚀 WhatsApp Gateway Deployment Script"
    echo "======================================"
    echo ""
    
    check_system
    install_requirements
    setup_project
    configure_environment
    setup_nginx
    deploy_application
    
    # Ask for SSL setup
    read -p "Do you want to setup SSL certificate? (recommended) (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        setup_ssl
    fi
    
    setup_firewall
    setup_monitoring
    final_check
    
    print_success "🎉 WhatsApp Gateway deployment completed!"
}

# Run main function
main "$@"