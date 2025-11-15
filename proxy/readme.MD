# Nginx Proxy Manager Configuration for FreeIPA

This document describes how to configure Nginx Proxy Manager (NPM) to reverse proxy FreeIPA.

## Overview

- **FreeIPA Server:** `https://ipa.internal.lcl` (internal)
- **Public URL:** `https://ipa.mycompany.com`
- **FreeIPA Version:** 4.12.2, API Version: 2.254

## Why NPM Requires Special Configuration

Nginx Proxy Manager uses **OpenResty** (nginx with Lua modules) and has a different configuration structure than standard nginx:

1. NPM's template system automatically generates `location /` blocks
2. NPM's `include conf.d/include/proxy.conf` sets default headers that need to be overridden
3. FreeIPA requires the internal hostname in the `Host` header
4. Redirects and URLs must be rewritten from internal to public domain

## Setup Steps in NPM

### 1. Create Proxy Host

In NPM's web interface:

1. Go to **Hosts** → **Proxy Hosts** → **Add Proxy Host**

2. **Details Tab:**
   - **Domain Names:** `ipa.mycompany.com`
   - **Scheme:** `https`
   - **Forward Hostname / IP:** `ipa.internal.lcl`
   - **Forward Port:** `443`
   - ✅ **Block Common Exploits**
   - ✅ **Websockets Support**

3. **SSL Tab:**
   - ✅ Select or request SSL certificate for `ipa.mycompany.com`
   - ✅ **Force SSL**
   - ✅ **HTTP/2 Support**
   - ✅ **HSTS Enabled**

### 2. Advanced Configuration

In the **Advanced** tab, paste the following configuration:

```nginx
# Redirect root to /ipa/ui/ directly from nginx
location = / {
    return 301 https://ipa.mycompany.com/ipa/ui/;
}

location / {
    # Set Host header to internal hostname
    proxy_set_header Host ipa.internal.lcl;
    
    # Other required headers
    proxy_set_header X-Forwarded-Scheme $scheme;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header Referer https://ipa.internal.lcl/ipa/ui;
    
    # WebSocket support
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $http_connection;
    proxy_http_version 1.1;
    
    # Cookie domain rewriting
    proxy_cookie_domain ipa.internal.lcl ipa.mycompany.com;
    
    # Redirect rewriting
    proxy_redirect https://ipa.internal.lcl https://ipa.mycompany.com;
    proxy_redirect http://ipa.internal.lcl https://ipa.mycompany.com;
    
    # Response body rewriting - catches JavaScript and HTML URLs
    sub_filter 'https://ipa.internal.lcl' 'https://ipa.mycompany.com';
    sub_filter 'http://ipa.internal.lcl' 'https://ipa.mycompany.com';
    sub_filter '"ipa.internal.lcl"' '"ipa.mycompany.com"';
    sub_filter "'ipa.internal.lcl'" "'ipa.mycompany.com'";
    sub_filter_once off;
    sub_filter_types text/html text/css text/xml text/javascript application/javascript application/json;
    
    # Disable compression for sub_filter to work
    proxy_set_header Accept-Encoding "";
    
    # Timeouts
    proxy_connect_timeout 150;
    proxy_send_timeout 100;
    proxy_read_timeout 100;
    
    # Buffers
    proxy_buffers 4 32k;
    client_max_body_size 200M;
    
    # Proxy pass
    proxy_pass $forward_scheme://$server:$port$request_uri;
    
    # Security headers
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header Strict-Transport-Security "max-age=63072000" always;
}
```

4. **Save** the proxy host

## Configuration Explanation

### Critical Settings

1. **`proxy_set_header Host ipa.internal.lcl`**
   - FreeIPA validates the Host header and needs to see its internal hostname
   - Without this, FreeIPA will reject requests or behave incorrectly

2. **`proxy_cookie_domain ipa.internal.lcl ipa.mycompany.com`**
   - Rewrites cookies from the internal domain to the public domain
   - Essential for session persistence and login to work

3. **`proxy_redirect`**
   - Intercepts HTTP `Location` headers in 301/302 redirects
   - Rewrites internal URLs to public URLs
   - Prevents browser from being redirected to internal hostname

4. **`sub_filter` directives**
   - Rewrites URLs in HTML, JavaScript, CSS, and JSON responses
   - Catches client-side redirects like `window.location.href = '...'`
   - Required because FreeIPA embeds URLs in JavaScript code

5. **`proxy_set_header Accept-Encoding ""`**
   - Disables gzip compression from backend
   - CRITICAL: `sub_filter` only works on uncompressed responses
   - Slight performance tradeoff for URL rewriting to function

6. **`location = /` block**
   - Handles root path redirect directly from nginx
   - Prevents FreeIPA's redirect from reaching the browser
   - Ensures browser never sees internal hostname

### Buffer and Timeout Settings

- **`client_max_body_size 200M`** - Allows large file uploads
- **`proxy_buffers 4 32k`** - Handles large headers and cookies
- **`proxy_*_timeout 100-150s`** - Accommodates slow API calls


