#!/bin/bash

# Simplified Deployment Script for Existing Server with n8n
# Target: Debian droplet with n8n already running

set -e

echo "🚀 Deploying WhatsApp Gateway to existing server..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if we're in the right directory
if [ ! -f "docker-compose.yml" ]; then
    print_error "docker-compose.yml not found. Please run this script from the wa-gateway directory."
    exit 1
fi

# Step 1: Setup project directories
setup_directories() {
    print_status "Setting up directories..."
    
    sudo mkdir -p /opt/wa-gateway/{wa_credentials,media,logs,backups}
    sudo chown -R 1001:1001 /opt/wa-gateway/wa_credentials /opt/wa-gateway/media
    sudo chown -R $USER:$USER /opt/wa-gateway
    
    print_success "Directories created"
}

# Step 2: Configure environment
setup_environment() {
    print_status "Setting up environment..."
    
    if [ ! -f .env ]; then
        cp .env.docker .env
        
        # Generate secure API key
        API_KEY=$(openssl rand -base64 32)
        sed -i "s/your-super-secure-api-key-here/$API_KEY/" .env
        
        print_success "Environment configured"
        print_warning "Your API Key: $API_KEY"
        print_warning "SAVE THIS KEY! You'll need it to access the API."
        
        echo ""
        read -p "Enter your webhook URL (optional, press Enter to skip): " WEBHOOK_URL
        if [ ! -z "$WEBHOOK_URL" ]; then
            sed -i "s|# WEBHOOK_BASE_URL=https://your-webhook-domain.com|WEBHOOK_BASE_URL=$WEBHOOK_URL|" .env
        fi
    else
        print_warning ".env file already exists, skipping configuration"
    fi
}

# Step 3: Add rate limiting to nginx main config
setup_rate_limiting() {
    print_status "Adding rate limiting to nginx config..."
    
    # Check if rate limiting already exists
    if ! grep -q "limit_req_zone.*wa_gateway" /etc/nginx/nginx.conf; then
        # Backup nginx.conf
        sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup
        
        # Add rate limiting to http block
        sudo sed -i '/http {/a\\n\t# Rate limiting for WA Gateway\n\tlimit_req_zone $binary_remote_addr zone=wa_gateway:10m rate=10r/s;\n' /etc/nginx/nginx.conf
        
        print_success "Rate limiting added to nginx.conf"
    else
        print_warning "Rate limiting already configured"
    fi
}

# Step 4: Setup nginx configuration for WA Gateway
setup_nginx() {
    print_status "Setting up nginx configuration for wa.fauzi.tech..."
    
    # Create nginx site config
    sudo tee /etc/nginx/sites-available/wa-gateway > /dev/null << 'EOF'
server {
    listen 80;
    server_name wa.fauzi.tech;
    
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name wa.fauzi.tech;

    ssl_certificate /etc/letsencrypt/live/wa.fauzi.tech/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/wa.fauzi.tech/privkey.pem;
    
    # Security headers
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options DENY;
    add_header X-XSS-Protection "1; mode=block";
    add_header Referrer-Policy "strict-origin-when-cross-origin";
    
    location / {
        limit_req zone=wa_gateway burst=20 nodelay;
        
        proxy_pass http://127.0.0.1:5001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
        proxy_read_timeout 86400;
        
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
    }
    
    location /media/ {
        proxy_pass http://127.0.0.1:5001;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
    
    location /health {
        proxy_pass http://127.0.0.1:5001/health;
        access_log off;
    }
    
    location ~ \.(env|config|ini)$ {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF
    
    # Enable the site
    sudo ln -sf /etc/nginx/sites-available/wa-gateway /etc/nginx/sites-enabled/
    
    # Test nginx config
    if sudo nginx -t; then
        sudo systemctl reload nginx
        print_success "Nginx configuration updated"
    else
        print_error "Nginx configuration test failed"
        exit 1
    fi
}

# Step 5: Deploy the application
deploy_app() {
    print_status "Building and deploying WhatsApp Gateway..."
    
    # Build and start the container
    docker-compose up -d --build
    
    # Wait for container to start
    print_status "Waiting for application to start..."
    sleep 30
    
    # Check if container is running
    if docker-compose ps | grep -q "Up"; then
        print_success "Application deployed successfully!"
        
        # Test health endpoint
        sleep 10
        if curl -s http://127.0.0.1:5001/health > /dev/null; then
            print_success "Application is healthy!"
        else
            print_warning "Application might need more time to start"
        fi
    else
        print_error "Application failed to start. Check logs with: docker-compose logs"
        exit 1
    fi
}

# Step 6: Setup SSL for wa.fauzi.tech
setup_ssl() {
    print_status "Setting up SSL certificate for wa.fauzi.tech..."
    
    # Get SSL certificate using certbot
    if command -v certbot >/dev/null 2>&1; then
        sudo certbot --nginx -d wa.fauzi.tech --non-interactive --agree-tos --email admin@fauzi.tech
        print_success "SSL certificate configured for wa.fauzi.tech"
    else
        print_warning "Certbot not found. Please install certbot and run:"
        print_warning "sudo certbot --nginx -d wa.fauzi.tech"
    fi
}

# Step 7: Setup monitoring and backup
setup_monitoring() {
    print_status "Setting up monitoring and backup..."
    
    # Create backup script
    cat > /opt/wa-gateway/backup.sh << 'EOF'
#!/bin/bash
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/opt/wa-gateway/backups"

cd /opt/wa-gateway
tar -czf $BACKUP_DIR/wa-gateway-$DATE.tar.gz wa_credentials/ media/ .env

# Keep only last 7 days
find $BACKUP_DIR -name "wa-gateway-*.tar.gz" -mtime +7 -delete

echo "$(date): Backup completed - wa-gateway-$DATE.tar.gz" >> logs/backup.log
EOF
    
    chmod +x /opt/wa-gateway/backup.sh
    
    # Add to crontab if not exists
    if ! crontab -l 2>/dev/null | grep -q "wa-gateway/backup.sh"; then
        (crontab -l 2>/dev/null; echo "0 2 * * * /opt/wa-gateway/backup.sh") | crontab -
        print_success "Daily backup scheduled at 2 AM"
    fi
    
    print_success "Monitoring setup completed"
}

# Main execution
main() {
    echo "🚀 WhatsApp Gateway Deployment"
    echo "Target: wa.fauzi.tech"
    echo "=============================="
    echo ""
    
    # Confirm deployment
    read -p "This will deploy WA Gateway alongside existing n8n. Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Deployment cancelled."
        exit 0
    fi
    
    setup_directories
    setup_environment
    setup_rate_limiting
    setup_nginx
    deploy_app
    
    # Ask for SSL setup
    read -p "Setup SSL certificate for wa.fauzi.tech? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        setup_ssl
    fi
    
    setup_monitoring
    
    echo ""
    echo "🎉 Deployment completed successfully!"
    echo ""
    echo "📋 Access Information:"
    echo "   Application URL: https://wa.fauzi.tech"
    echo "   API Key: $(grep WA_GATEWAY_KEY .env | cut -d'=' -f2)"
    echo "   Health Check: https://wa.fauzi.tech/health"
    echo ""
    echo "🔧 Useful Commands:"
    echo "   View logs: docker-compose logs -f"
    echo "   Restart: docker-compose restart"
    echo "   Stop: docker-compose down"
    echo "   Manual backup: /opt/wa-gateway/backup.sh"
    echo ""
    echo "📱 Next Steps:"
    echo "   1. Add DNS record: wa.fauzi.tech -> 152.42.198.49"
    echo "   2. Test API endpoints"
    echo "   3. Create WhatsApp session"
    echo "   4. Configure webhooks if needed"
    echo ""
    echo "🔗 Repository: https://github.com/muhfauziazhar/wa-gateway"
    
    print_success "🎉 Ready to use!"
}

# Run main function
main "$@"