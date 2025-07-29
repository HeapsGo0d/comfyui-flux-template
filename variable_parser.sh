#!/usr/bin/env bash
# =============================================================================
# VARIABLE PARSING MODULE - Robust Environment Variable Handling
# =============================================================================
# This module provides a comprehensive framework for parsing, validating, and
# displaying environment variables used in the ComfyUI-Flux container.
#
# Features:
# - Type-specific parsing and validation (boolean, integer, string, csv, token)
# - Centralized configuration management
# - Automatic default value handling
# - Secure handling of sensitive values
# - Comprehensive error reporting
# - Runtime configuration display

# Global variable configuration
declare -A CONFIG=()           # Store all parsed configuration values
declare -A CONFIG_DEFAULTS=()  # Store default values
declare -A CONFIG_TYPES=()     # Store variable types
declare -A CONFIG_DESCR=()     # Store variable descriptions
declare -A CONFIG_VALIDATORS=() # Store custom validation functions
declare -A CONFIG_EXAMPLES=()  # Store example values
declare -A CONFIG_CATEGORIES=() # Store variable categories

# Main function to parse an environment variable with validation
parse_variable() {
    local var_name="$1"
    local var_type="$2"
    local default_value="$3"
    local description="$4"
    local category="${5:-General}"
    local example="${6:-}"
    local custom_validator="${7:-}"
    
    # Register variable metadata
    CONFIG_TYPES["$var_name"]="$var_type"
    CONFIG_DEFAULTS["$var_name"]="$default_value"
    CONFIG_DESCR["$var_name"]="$description"
    CONFIG_CATEGORIES["$var_name"]="$category"
    [ -n "$example" ] && CONFIG_EXAMPLES["$var_name"]="$example"
    [ -n "$custom_validator" ] && CONFIG_VALIDATORS["$var_name"]="$custom_validator"
    
    # Get raw value with default
    local raw_value="${!var_name:-$default_value}"
    local parsed_value
    local validation_result=0
    
    # Type-specific parsing and validation
    case "$var_type" in
        boolean)
            parsed_value=$(parse_boolean "$raw_value")
            ;;
        integer)
            if ! parsed_value=$(parse_integer "$raw_value" "$default_value"); then
                validation_result=1
            fi
            ;;
        string)
            parsed_value="$raw_value"
            ;;
        csv)
            parsed_value=$(parse_csv "$raw_value")
            ;;
        token)
            if [ -n "$raw_value" ] && ! validate_token "$raw_value"; then
                log "WARN" "Invalid token format for $var_name, using empty value"
                parsed_value=""
                validation_result=1
            else
                parsed_value="$raw_value"
            fi
            ;;
        path)
            if [ -n "$raw_value" ] && ! validate_path "$raw_value"; then
                log "WARN" "Invalid path format for $var_name, using default: $default_value"
                parsed_value="$default_value"
                validation_result=1
            else
                parsed_value="$raw_value"
            fi
            ;;
        url)
            if [ -n "$raw_value" ] && ! validate_url "$raw_value"; then
                log "WARN" "Invalid URL format for $var_name, using default: $default_value"
                parsed_value="$default_value"
                validation_result=1
            else
                parsed_value="$raw_value"
            fi
            ;;
        *)
            log "WARN" "Unknown variable type '$var_type' for $var_name, treating as string"
            parsed_value="$raw_value"
            ;;
    esac
    
    # Apply custom validator if provided
    if [ -n "$custom_validator" ] && [ $validation_result -eq 0 ]; then
        if ! $custom_validator "$parsed_value"; then
            log "WARN" "Custom validation failed for $var_name, using default: $default_value"
            parsed_value="$default_value"
            validation_result=1
        fi
    fi
    
    # Log the parsing result (exclude tokens)
    if [ "$var_type" != "token" ]; then
        if [ $validation_result -eq 0 ]; then
            if [ "$var_type" = "csv" ] && [ -n "$parsed_value" ]; then
                local item_count=$(echo "$parsed_value" | tr ',' '\n' | wc -l)
                log "DEBUG" "Parsed $var_name: $item_count items"
            else
                log "DEBUG" "Parsed $var_name: $parsed_value"
            fi
        else
            log "WARN" "Failed to parse $var_name, using default/fallback value"
        fi
    else
        # For tokens, just log if they're set or not
        if [ -n "$parsed_value" ]; then
            log "DEBUG" "Using provided $var_name token"
        else
            log "DEBUG" "$var_name token not provided"
        fi
    fi
    
    # Store the parsed value
    CONFIG["$var_name"]="$parsed_value"
    
    # Export the variable for child processes
    export "$var_name"="$parsed_value"
    
    return $validation_result
}

# Parse boolean variables (true/false, yes/no, 1/0)
parse_boolean() {
    local value="$1"
    # Convert to lowercase
    value=$(echo "$value" | tr '[:upper:]' '[:lower:]')
    
    case "$value" in
        true|yes|1|y|on|enabled)
            echo "true"
            ;;
        *)
            echo "false"
            ;;
    esac
    return 0
}

# Parse integer variables with validation
parse_integer() {
    local value="$1"
    local default="$2"
    
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "$value"
        return 0
    else
        log "WARN" "Invalid integer value: '$value', using default: $default"
        echo "$default"
        return 1
    fi
}

# Enhanced comma-separated list parsing with special character handling
parse_csv() {
    local value="$1"
    local result=""
    
    # Handle empty case
    if [ -z "$value" ]; then
        echo ""
        return 0
    fi
    
    # First, handle quoted values by temporarily replacing commas inside quotes
    # This uses a placeholder that's unlikely to appear in the data
    local temp_value="$value"
    local placeholder="__COMMA__"
    
    # Replace commas inside quotes
    while [[ "$temp_value" =~ ([\'\"]).+?,[^\'\"]+ ]]; do
        temp_value=$(echo "$temp_value" | sed "s/\(['\"][^'\"]*\),\([^'\"]*['\"].\)/\1${placeholder}\2/g")
    done
    
    # Split the string by commas
    IFS=',' read -ra ITEMS <<< "$temp_value"
    
    # Process each item
    for item in "${ITEMS[@]}"; do
        # Trim whitespace
        item=$(echo "$item" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        
        # Restore commas from placeholder
        item=${item//$placeholder/,}
        
        # Remove surrounding quotes if present
        if [[ "$item" =~ ^\"(.*)\"$ || "$item" =~ ^\'(.*)\'$ ]]; then
            item="${BASH_REMATCH[1]}"
        fi
        
        # Skip empty items
        if [ -n "$item" ]; then
            # Add to result with proper separator
            if [ -z "$result" ]; then
                result="$item"
            else
                result="${result},${item}"
            fi
        fi
    done
    
    echo "$result"
    return 0
}

# Validate token format
validate_token() {
    local token="$1"
    
    # Basic validation - tokens are typically alphanumeric strings
    # with possible hyphens, underscores, and dots
    if [[ "$token" =~ ^[a-zA-Z0-9\._\-]{8,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Validate path format
validate_path() {
    local path="$1"
    
    # Basic path validation
    if [[ "$path" =~ ^[a-zA-Z0-9\._\-/]+$ ]]; then
        return 0
    else
        return 1
    fi
}

# Validate URL format
validate_url() {
    local url="$1"
    
    # Basic URL validation
    if [[ "$url" =~ ^https?:// ]]; then
        return 0
    else
        return 1
    fi
}

# Validate CivitAI model ID
validate_civitai_model_id() {
    local id="$1"
    
    # CivitAI model IDs are typically numeric
    if [[ "$id" =~ ^[0-9]+$ ]]; then
        return 0
    else
        return 1
    fi
}

# Validate HuggingFace repository format
validate_huggingface_repo() {
    local repo="$1"
    
    # HuggingFace repos typically follow format: username/repo-name
    if [[ "$repo" =~ ^[a-zA-Z0-9\._\-]+/[a-zA-Z0-9\._\-]+$ ]]; then
        return 0
    else
        return 1
    fi
}

# Check if a comma-separated list contains valid CivitAI model IDs
validate_civitai_model_ids() {
    local ids="$1"
    
    if [ -z "$ids" ]; then
        return 0
    fi
    
    local valid=0
    IFS=',' read -ra ID_ARRAY <<< "$ids"
    
    for id in "${ID_ARRAY[@]}"; do
        # Trim whitespace
        id=$(echo "$id" | xargs)
        
        if [ -z "$id" ]; then
            continue
        fi
        
        if ! validate_civitai_model_id "$id"; then
            log "WARN" "Invalid CivitAI model ID format: $id"
            valid=1
        fi
    done
    
    return $valid
}

# Check if a comma-separated list contains valid HuggingFace repos
validate_huggingface_repos() {
    local repos="$1"
    
    if [ -z "$repos" ]; then
        return 0
    fi
    
    local valid=0
    IFS=',' read -ra REPO_ARRAY <<< "$repos"
    
    for repo in "${REPO_ARRAY[@]}"; do
        # Trim whitespace
        repo=$(echo "$repo" | xargs)
        
        if [ -z "$repo" ]; then
            continue
        fi
        
        if ! validate_huggingface_repo "$repo"; then
            log "WARN" "Invalid HuggingFace repository format: $repo"
            valid=1
        fi
    done
    
    return $valid
}

# Display current configuration with sensitive values redacted
display_config() {
    log "INFO" "============================================================="
    log "INFO" "ComfyUI-Flux Container Configuration"
    log "INFO" "============================================================="
    
    # Get all categories
    local categories=()
    for var_name in "${!CONFIG_CATEGORIES[@]}"; do
        local category="${CONFIG_CATEGORIES[$var_name]}"
        if [[ ! " ${categories[*]} " =~ " ${category} " ]]; then
            categories+=("$category")
        fi
    done
    
    # Sort categories
    readarray -t sorted_categories < <(printf '%s\n' "${categories[@]}" | sort)
    
    # Process each category
    for category in "${sorted_categories[@]}"; do
        log "INFO" ""
        log "INFO" "$category Settings:"
        log "INFO" "-------------------------------------------------------------"
        
        # Get variables for this category
        local category_vars=()
        for var_name in "${!CONFIG_CATEGORIES[@]}"; do
            if [ "${CONFIG_CATEGORIES[$var_name]}" = "$category" ]; then
                category_vars+=("$var_name")
            fi
        done
        
        # Sort variables within category
        readarray -t sorted_vars < <(printf '%s\n' "${category_vars[@]}" | sort)
        
        # Calculate the maximum variable name length for alignment
        local max_length=0
        for var_name in "${sorted_vars[@]}"; do
            if [ ${#var_name} -gt $max_length ]; then
                max_length=${#var_name}
            fi
        done
        
        # Display each variable with its value and description
        for var_name in "${sorted_vars[@]}"; do
            local var_type="${CONFIG_TYPES[$var_name]}"
            local var_value="${CONFIG[$var_name]}"
            local var_descr="${CONFIG_DESCR[$var_name]}"
            local padding=$((max_length - ${#var_name} + 2))
            local pad_str=$(printf '%*s' "$padding" '')
            
            # Redact sensitive information
            if [ "$var_type" = "token" ]; then
                if [ -n "$var_value" ]; then
                    var_value="[SET]"
                else
                    var_value="[NOT SET]"
                fi
            fi
            
            # Format boolean values for clearer display
            if [ "$var_type" = "boolean" ]; then
                if [ "$var_value" = "true" ]; then
                    var_value="Enabled"
                else
                    var_value="Disabled"
                fi
            fi
            
            # Special formatting for CSV values
            if [ "$var_type" = "csv" ]; then
                if [ -n "$var_value" ]; then
                    local item_count=$(echo "$var_value" | tr ',' '\n' | wc -l)
                    # Show first 3 items and count
                    var_value="$item_count items: "
                    local items_preview=""
                    local count=0
                    IFS=',' read -ra ITEMS <<< "$var_value"
                    for item in "${ITEMS[@]}"; do
                        ((count++))
                        if [ $count -le 3 ]; then
                            if [ -z "$items_preview" ]; then
                                items_preview="$item"
                            else
                                items_preview="$items_preview, $item"
                            fi
                        else
                            break
                        fi
                    done
                    if [ $item_count -gt 3 ]; then
                        var_value="$var_value$items_preview, ..."
                    else
                        var_value="$var_value$items_preview"
                    fi
                else
                    var_value="[NONE]"
                fi
            fi
            
            log "CONFIG" "${var_name}${pad_str}= ${var_value}"
        done
    done
    
    log "INFO" "============================================================="
}

# Initialize all environment variables with comprehensive documentation
initialize_variables() {
    log "INFO" "Initializing environment variables..."
    
    # Debug and logging
    parse_variable "DEBUG_MODE" "boolean" "false" \
        "Enable verbose debug output and additional logging" \
        "Logging" "true"
    
    # File storage
    parse_variable "USE_VOLUME" "boolean" "false" \
        "Use persistent storage volume for models and outputs" \
        "Storage" "true"
    
    # Services
    parse_variable "FILEBROWSER" "boolean" "false" \
        "Enable the FileBrowser web interface for file management" \
        "Services" "true"
    
    parse_variable "FB_USERNAME" "string" "admin" \
        "Username for the FileBrowser interface" \
        "Services" "admin"
    
    parse_variable "FB_PASSWORD" "token" "" \
        "Password for FileBrowser (auto-generated if empty)" \
        "Services" "strongpassword123"
    
    # Model downloads - CivitAI
    parse_variable "CHECKPOINT_IDS_TO_DOWNLOAD" "csv" "" \
        "Comma-separated list of CivitAI checkpoint model IDs to download" \
        "Model Downloads" "12345,67890,112233" \
        validate_civitai_model_ids
    
    parse_variable "LORA_IDS_TO_DOWNLOAD" "csv" "" \
        "Comma-separated list of CivitAI LoRA model IDs to download" \
        "Model Downloads" "45678,89012" \
        validate_civitai_model_ids
    
    parse_variable "VAE_IDS_TO_DOWNLOAD" "csv" "" \
        "Comma-separated list of CivitAI VAE model IDs to download" \
        "Model Downloads" "13579,24680" \
        validate_civitai_model_ids
    
    parse_variable "CIVITAI_TOKEN" "token" "" \
        "CivitAI API token for accessing private models" \
        "Model Downloads" "civitai_xxxxxxxxxxxxxxxx"
    
    # Model downloads - HuggingFace
    parse_variable "HUGGINGFACE_REPOS" "csv" "" \
        "Comma-separated list of HuggingFace repositories to download" \
        "Model Downloads" "username/repo-name,organization/model-name" \
        validate_huggingface_repos
    
    parse_variable "HUGGINGFACE_TOKEN" "token" "" \
        "HuggingFace API token for accessing private repositories" \
        "Model Downloads" "hf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    
    # Display effective configuration
    display_config
}