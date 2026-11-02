/* eslint-disable */
// AUTO-GENERATED — DO NOT EDIT
// Run migrations to regenerate.

export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.18"
  }
  public: {
    Tables: {
      account_deletion_requests: {
        Row: {
          created_at: string
          email: string | null
          id: string
          reason: string | null
          status: string
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          email?: string | null
          id?: string
          reason?: string | null
          status?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          email?: string | null
          id?: string
          reason?: string | null
          status?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "account_deletion_requests_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      app_notices: {
        Row: {
          client_updated_at: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          ends_at: string | null
          id: string
          is_active: boolean
          message: string
          notice_type: string
          priority: number
          starts_at: string | null
          sync_version: number
          title: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          client_updated_at?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          ends_at?: string | null
          id?: string
          is_active?: boolean
          message: string
          notice_type?: string
          priority?: number
          starts_at?: string | null
          sync_version?: number
          title: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          client_updated_at?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          ends_at?: string | null
          id?: string
          is_active?: boolean
          message?: string
          notice_type?: string
          priority?: number
          starts_at?: string | null
          sync_version?: number
          title?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      app_release_policy: {
        Row: {
          active: boolean
          latest_build: number
          latest_version: string
          minimum_supported_build: number
          minimum_supported_version: string
          platform: string
          store_url: string
          update_message: string
          update_title: string
          updated_at: string
        }
        Insert: {
          active?: boolean
          latest_build: number
          latest_version: string
          minimum_supported_build: number
          minimum_supported_version: string
          platform: string
          store_url: string
          update_message: string
          update_title: string
          updated_at?: string
        }
        Update: {
          active?: boolean
          latest_build?: number
          latest_version?: string
          minimum_supported_build?: number
          minimum_supported_version?: string
          platform?: string
          store_url?: string
          update_message?: string
          update_title?: string
          updated_at?: string
        }
        Relationships: []
      }
      audit_events: {
        Row: {
          action: string
          created_at: string
          details: string | null
          entity_id: string | null
          entity_type: string
          id: string
          user_id: string | null
          vineyard_id: string | null
        }
        Insert: {
          action: string
          created_at?: string
          details?: string | null
          entity_id?: string | null
          entity_type: string
          id?: string
          user_id?: string | null
          vineyard_id?: string | null
        }
        Update: {
          action?: string
          created_at?: string
          details?: string | null
          entity_id?: string | null
          entity_type?: string
          id?: string
          user_id?: string | null
          vineyard_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "audit_events_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "audit_events_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      axisstream_exchange_connections: {
        Row: {
          created_at: string
          last_test_status: string
          last_test_summary: Json
          last_tested_at: string | null
          live_publish_enabled: boolean
          mode: string
          selected_leaf_code: string | null
          selected_rain_code: string | null
          selected_weather_code: string | null
          token_secret_id: string | null
          updated_at: string
          updated_by: string | null
          vineyard_id: string
        }
        Insert: {
          created_at?: string
          last_test_status?: string
          last_test_summary?: Json
          last_tested_at?: string | null
          live_publish_enabled?: boolean
          mode?: string
          selected_leaf_code?: string | null
          selected_rain_code?: string | null
          selected_weather_code?: string | null
          token_secret_id?: string | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
        }
        Update: {
          created_at?: string
          last_test_status?: string
          last_test_summary?: Json
          last_tested_at?: string | null
          live_publish_enabled?: boolean
          mode?: string
          selected_leaf_code?: string | null
          selected_rain_code?: string | null
          selected_weather_code?: string | null
          token_secret_id?: string | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "axisstream_exchange_connections_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: true
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      axisstream_exchange_devices: {
        Row: {
          dataset: string
          device_code: string
          device_name: string | null
          discovered_at: string
          last_seen_at: string | null
          latitude: number | null
          longitude: number | null
          project_code: string
          vineyard_id: string
        }
        Insert: {
          dataset: string
          device_code: string
          device_name?: string | null
          discovered_at?: string
          last_seen_at?: string | null
          latitude?: number | null
          longitude?: number | null
          project_code: string
          vineyard_id: string
        }
        Update: {
          dataset?: string
          device_code?: string
          device_name?: string | null
          discovered_at?: string
          last_seen_at?: string | null
          latitude?: number | null
          longitude?: number | null
          project_code?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "axisstream_exchange_devices_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "axisstream_exchange_connections"
            referencedColumns: ["vineyard_id"]
          },
        ]
      }
      axisstream_exchange_staged_readings: {
        Row: {
          dataset: string
          device_code: string
          fetched_at: string
          observed_at: string
          payload: Json
          project_code: string
          vineyard_id: string
        }
        Insert: {
          dataset: string
          device_code: string
          fetched_at?: string
          observed_at: string
          payload: Json
          project_code: string
          vineyard_id: string
        }
        Update: {
          dataset?: string
          device_code?: string
          fetched_at?: string
          observed_at?: string
          payload?: Json
          project_code?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "axisstream_exchange_staged_readings_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "axisstream_exchange_connections"
            referencedColumns: ["vineyard_id"]
          },
        ]
      }
      billing_admin_alerts: {
        Row: {
          acknowledged_at: string | null
          acknowledged_by: string | null
          alert_type: string
          created_at: string
          detail: string | null
          event_type: string | null
          id: string
          product_id: string | null
          provider: string | null
          provider_event_id: string | null
          resolved_user_id: string | null
          severity: string
        }
        Insert: {
          acknowledged_at?: string | null
          acknowledged_by?: string | null
          alert_type: string
          created_at?: string
          detail?: string | null
          event_type?: string | null
          id?: string
          product_id?: string | null
          provider?: string | null
          provider_event_id?: string | null
          resolved_user_id?: string | null
          severity?: string
        }
        Update: {
          acknowledged_at?: string | null
          acknowledged_by?: string | null
          alert_type?: string
          created_at?: string
          detail?: string | null
          event_type?: string | null
          id?: string
          product_id?: string | null
          provider?: string | null
          provider_event_id?: string | null
          resolved_user_id?: string | null
          severity?: string
        }
        Relationships: []
      }
      billing_product_catalog: {
        Row: {
          created_at: string
          ends_at: string | null
          entitlement_id: string
          environment: string
          external_product_id: string
          id: string
          is_active: boolean
          licence_quantity: number
          metadata: Json
          plan_code: string
          platform: string
          provider: string
          starts_at: string | null
          updated_at: string
        }
        Insert: {
          created_at?: string
          ends_at?: string | null
          entitlement_id?: string
          environment?: string
          external_product_id: string
          id?: string
          is_active?: boolean
          licence_quantity?: number
          metadata?: Json
          plan_code: string
          platform: string
          provider?: string
          starts_at?: string | null
          updated_at?: string
        }
        Update: {
          created_at?: string
          ends_at?: string | null
          entitlement_id?: string
          environment?: string
          external_product_id?: string
          id?: string
          is_active?: boolean
          licence_quantity?: number
          metadata?: Json
          plan_code?: string
          platform?: string
          provider?: string
          starts_at?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "billing_product_catalog_plan_code_fkey"
            columns: ["plan_code"]
            isOneToOne: false
            referencedRelation: "vinetrack_plans"
            referencedColumns: ["code"]
          },
        ]
      }
      billing_provider_events: {
        Row: {
          aliases: string[] | null
          app_user_id: string | null
          dismissal_reason: string | null
          dismissed_at: string | null
          dismissed_by: string | null
          entitlement_ids: string[] | null
          environment: string | null
          event_type: string
          external_subscription_id: string | null
          external_transaction_id: string | null
          id: string
          last_retry_at: string | null
          last_retry_by: string | null
          original_app_user_id: string | null
          payload_hash: string | null
          platform: string | null
          processed_at: string | null
          processing_error_code: string | null
          processing_error_message: string | null
          processing_status: string
          product_id: string | null
          provider: string
          provider_created_at: string | null
          provider_event_id: string
          raw_payload: Json | null
          received_at: string
          resolution_action: string | null
          resolution_reason: string | null
          resolved_at: string | null
          resolved_by: string | null
          resolved_user_id: string | null
          retry_count: number
          review_item_type: string | null
          store: string | null
        }
        Insert: {
          aliases?: string[] | null
          app_user_id?: string | null
          dismissal_reason?: string | null
          dismissed_at?: string | null
          dismissed_by?: string | null
          entitlement_ids?: string[] | null
          environment?: string | null
          event_type: string
          external_subscription_id?: string | null
          external_transaction_id?: string | null
          id?: string
          last_retry_at?: string | null
          last_retry_by?: string | null
          original_app_user_id?: string | null
          payload_hash?: string | null
          platform?: string | null
          processed_at?: string | null
          processing_error_code?: string | null
          processing_error_message?: string | null
          processing_status?: string
          product_id?: string | null
          provider: string
          provider_created_at?: string | null
          provider_event_id: string
          raw_payload?: Json | null
          received_at?: string
          resolution_action?: string | null
          resolution_reason?: string | null
          resolved_at?: string | null
          resolved_by?: string | null
          resolved_user_id?: string | null
          retry_count?: number
          review_item_type?: string | null
          store?: string | null
        }
        Update: {
          aliases?: string[] | null
          app_user_id?: string | null
          dismissal_reason?: string | null
          dismissed_at?: string | null
          dismissed_by?: string | null
          entitlement_ids?: string[] | null
          environment?: string | null
          event_type?: string
          external_subscription_id?: string | null
          external_transaction_id?: string | null
          id?: string
          last_retry_at?: string | null
          last_retry_by?: string | null
          original_app_user_id?: string | null
          payload_hash?: string | null
          platform?: string | null
          processed_at?: string | null
          processing_error_code?: string | null
          processing_error_message?: string | null
          processing_status?: string
          product_id?: string | null
          provider?: string
          provider_created_at?: string | null
          provider_event_id?: string
          raw_payload?: Json | null
          received_at?: string
          resolution_action?: string | null
          resolution_reason?: string | null
          resolved_at?: string | null
          resolved_by?: string | null
          resolved_user_id?: string | null
          retry_count?: number
          review_item_type?: string | null
          store?: string | null
        }
        Relationships: []
      }
      chemical_enrichment_cache: {
        Row: {
          cache_key: string
          created_at: string
          expires_at: string
          parser_version: string
          payload: Json
          refreshed_at: string
          registration_country: string
          registration_number: string
          registration_scheme: string | null
        }
        Insert: {
          cache_key: string
          created_at?: string
          expires_at: string
          parser_version: string
          payload: Json
          refreshed_at?: string
          registration_country: string
          registration_number: string
          registration_scheme?: string | null
        }
        Update: {
          cache_key?: string
          created_at?: string
          expires_at?: string
          parser_version?: string
          payload?: Json
          refreshed_at?: string
          registration_country?: string
          registration_number?: string
          registration_scheme?: string | null
        }
        Relationships: []
      }
      chemical_inventory_purchases: {
        Row: {
          base_unit: string
          batch_date: string | null
          batch_number: string
          capacity_base: number | null
          container_count: number | null
          container_size: number | null
          container_unit: string | null
          created_at: string
          created_by: string
          currency: string
          expiry_date: string | null
          id: string
          invoice_reference: string | null
          notes: string | null
          purchase_date: string
          quantity: number
          quantity_base: number
          saved_chemical_id: string
          serial_number: string | null
          supplier: string | null
          total_cost: number
          unit: string
          updated_at: string
          vineyard_id: string
        }
        Insert: {
          base_unit: string
          batch_date?: string | null
          batch_number?: string
          capacity_base?: number | null
          container_count?: number | null
          container_size?: number | null
          container_unit?: string | null
          created_at?: string
          created_by: string
          currency?: string
          expiry_date?: string | null
          id?: string
          invoice_reference?: string | null
          notes?: string | null
          purchase_date?: string
          quantity: number
          quantity_base: number
          saved_chemical_id: string
          serial_number?: string | null
          supplier?: string | null
          total_cost: number
          unit: string
          updated_at?: string
          vineyard_id: string
        }
        Update: {
          base_unit?: string
          batch_date?: string | null
          batch_number?: string
          capacity_base?: number | null
          container_count?: number | null
          container_size?: number | null
          container_unit?: string | null
          created_at?: string
          created_by?: string
          currency?: string
          expiry_date?: string | null
          id?: string
          invoice_reference?: string | null
          notes?: string | null
          purchase_date?: string
          quantity?: number
          quantity_base?: number
          saved_chemical_id?: string
          serial_number?: string | null
          supplier?: string | null
          total_cost?: number
          unit?: string
          updated_at?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "chemical_inventory_purchases_saved_chemical_id_fkey"
            columns: ["saved_chemical_id"]
            isOneToOne: false
            referencedRelation: "saved_chemical_intelligence_audit"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chemical_inventory_purchases_saved_chemical_id_fkey"
            columns: ["saved_chemical_id"]
            isOneToOne: false
            referencedRelation: "saved_chemicals"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chemical_inventory_purchases_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      chemical_inventory_settings: {
        Row: {
          created_at: string
          created_by: string
          low_stock_percent: number
          low_stock_threshold_base: number | null
          low_stock_threshold_quantity: number | null
          low_stock_threshold_unit: string | null
          saved_chemical_id: string
          updated_at: string
          vineyard_id: string
          warnings_enabled: boolean
        }
        Insert: {
          created_at?: string
          created_by: string
          low_stock_percent?: number
          low_stock_threshold_base?: number | null
          low_stock_threshold_quantity?: number | null
          low_stock_threshold_unit?: string | null
          saved_chemical_id: string
          updated_at?: string
          vineyard_id: string
          warnings_enabled?: boolean
        }
        Update: {
          created_at?: string
          created_by?: string
          low_stock_percent?: number
          low_stock_threshold_base?: number | null
          low_stock_threshold_quantity?: number | null
          low_stock_threshold_unit?: string | null
          saved_chemical_id?: string
          updated_at?: string
          vineyard_id?: string
          warnings_enabled?: boolean
        }
        Relationships: [
          {
            foreignKeyName: "chemical_inventory_settings_saved_chemical_id_fkey"
            columns: ["saved_chemical_id"]
            isOneToOne: true
            referencedRelation: "saved_chemical_intelligence_audit"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chemical_inventory_settings_saved_chemical_id_fkey"
            columns: ["saved_chemical_id"]
            isOneToOne: true
            referencedRelation: "saved_chemicals"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chemical_inventory_settings_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      chemical_inventory_stocktakes: {
        Row: {
          base_unit: string
          capacity_base: number | null
          container_count: number | null
          container_size: number | null
          container_unit: string | null
          created_at: string
          created_by: string
          effective_at: string
          id: string
          notes: string | null
          quantity: number
          quantity_base: number
          reason: string
          saved_chemical_id: string
          unit: string
          vineyard_id: string
        }
        Insert: {
          base_unit: string
          capacity_base?: number | null
          container_count?: number | null
          container_size?: number | null
          container_unit?: string | null
          created_at?: string
          created_by: string
          effective_at?: string
          id?: string
          notes?: string | null
          quantity: number
          quantity_base: number
          reason: string
          saved_chemical_id: string
          unit: string
          vineyard_id: string
        }
        Update: {
          base_unit?: string
          capacity_base?: number | null
          container_count?: number | null
          container_size?: number | null
          container_unit?: string | null
          created_at?: string
          created_by?: string
          effective_at?: string
          id?: string
          notes?: string | null
          quantity?: number
          quantity_base?: number
          reason?: string
          saved_chemical_id?: string
          unit?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "chemical_inventory_stocktakes_saved_chemical_id_fkey"
            columns: ["saved_chemical_id"]
            isOneToOne: false
            referencedRelation: "saved_chemical_intelligence_audit"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chemical_inventory_stocktakes_saved_chemical_id_fkey"
            columns: ["saved_chemical_id"]
            isOneToOne: false
            referencedRelation: "saved_chemicals"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chemical_inventory_stocktakes_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      chemical_product_categories: {
        Row: {
          category_key: string
          created_at: string
          is_active: boolean
          label: string
          resistance_relevant: boolean
          sort_order: number
          updated_at: string
        }
        Insert: {
          category_key: string
          created_at?: string
          is_active?: boolean
          label: string
          resistance_relevant?: boolean
          sort_order?: number
          updated_at?: string
        }
        Update: {
          category_key?: string
          created_at?: string
          is_active?: boolean
          label?: string
          resistance_relevant?: boolean
          sort_order?: number
          updated_at?: string
        }
        Relationships: []
      }
      chemical_research_suggestion_cache: {
        Row: {
          cache_key: string
          country_code: string
          created_at: string
          expires_at: string
          normalised_query: string
          payload: Json
        }
        Insert: {
          cache_key: string
          country_code: string
          created_at?: string
          expires_at: string
          normalised_query: string
          payload: Json
        }
        Update: {
          cache_key?: string
          country_code?: string
          created_at?: string
          expires_at?: string
          normalised_query?: string
          payload?: Json
        }
        Relationships: []
      }
      chemical_v3_discovery_jobs: {
        Row: {
          attempt_count: number
          completed_at: string | null
          country_code: string | null
          created_at: string
          created_by: string
          dedupe_key: string
          error_code: string | null
          error_message: string | null
          estimated_cost_usd: number
          id: string
          input_kind: string
          job_type: string
          normalized_query: string | null
          photo_path: string | null
          product_id: string | null
          progress_percent: number
          provider: string | null
          provider_usage: Json
          query_text: string | null
          research_hint_history: Json
          research_hints: Json
          revision_id: string | null
          stage: string
          started_at: string | null
          status: string
          updated_at: string
          user_message: string | null
        }
        Insert: {
          attempt_count?: number
          completed_at?: string | null
          country_code?: string | null
          created_at?: string
          created_by: string
          dedupe_key: string
          error_code?: string | null
          error_message?: string | null
          estimated_cost_usd?: number
          id?: string
          input_kind?: string
          job_type?: string
          normalized_query?: string | null
          photo_path?: string | null
          product_id?: string | null
          progress_percent?: number
          provider?: string | null
          provider_usage?: Json
          query_text?: string | null
          research_hint_history?: Json
          research_hints?: Json
          revision_id?: string | null
          stage?: string
          started_at?: string | null
          status?: string
          updated_at?: string
          user_message?: string | null
        }
        Update: {
          attempt_count?: number
          completed_at?: string | null
          country_code?: string | null
          created_at?: string
          created_by?: string
          dedupe_key?: string
          error_code?: string | null
          error_message?: string | null
          estimated_cost_usd?: number
          id?: string
          input_kind?: string
          job_type?: string
          normalized_query?: string | null
          photo_path?: string | null
          product_id?: string | null
          progress_percent?: number
          provider?: string | null
          provider_usage?: Json
          query_text?: string | null
          research_hint_history?: Json
          research_hints?: Json
          revision_id?: string | null
          stage?: string
          started_at?: string | null
          status?: string
          updated_at?: string
          user_message?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "chemical_v3_discovery_jobs_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "chemical_v3_products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chemical_v3_discovery_jobs_revision_id_fkey"
            columns: ["revision_id"]
            isOneToOne: false
            referencedRelation: "chemical_v3_product_revisions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chemical_v3_discovery_jobs_revision_id_fkey"
            columns: ["revision_id"]
            isOneToOne: false
            referencedRelation: "saved_chemicals_effective"
            referencedColumns: ["effective_catalogue_revision_id"]
          },
        ]
      }
      chemical_v3_documents: {
        Row: {
          byte_size: number | null
          created_at: string
          document_role: string
          fetched_at: string | null
          id: string
          is_current: boolean
          job_id: string | null
          metadata: Json
          mime_type: string | null
          original_url: string | null
          physical_page: number | null
          revision_id: string | null
          sha256: string | null
          source_host: string | null
          storage_path: string | null
          version_label: string | null
        }
        Insert: {
          byte_size?: number | null
          created_at?: string
          document_role: string
          fetched_at?: string | null
          id?: string
          is_current?: boolean
          job_id?: string | null
          metadata?: Json
          mime_type?: string | null
          original_url?: string | null
          physical_page?: number | null
          revision_id?: string | null
          sha256?: string | null
          source_host?: string | null
          storage_path?: string | null
          version_label?: string | null
        }
        Update: {
          byte_size?: number | null
          created_at?: string
          document_role?: string
          fetched_at?: string | null
          id?: string
          is_current?: boolean
          job_id?: string | null
          metadata?: Json
          mime_type?: string | null
          original_url?: string | null
          physical_page?: number | null
          revision_id?: string | null
          sha256?: string | null
          source_host?: string | null
          storage_path?: string | null
          version_label?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "chemical_v3_documents_job_id_fkey"
            columns: ["job_id"]
            isOneToOne: false
            referencedRelation: "chemical_v3_discovery_jobs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chemical_v3_documents_revision_id_fkey"
            columns: ["revision_id"]
            isOneToOne: false
            referencedRelation: "chemical_v3_product_revisions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chemical_v3_documents_revision_id_fkey"
            columns: ["revision_id"]
            isOneToOne: false
            referencedRelation: "saved_chemicals_effective"
            referencedColumns: ["effective_catalogue_revision_id"]
          },
        ]
      }
      chemical_v3_ingredient_edit_audit: {
        Row: {
          changed_at: string
          changed_by: string
          id: string
          new_ingredients: Json
          previous_ingredients: Json
          product_id: string
          revision_id: string
        }
        Insert: {
          changed_at?: string
          changed_by: string
          id?: string
          new_ingredients: Json
          previous_ingredients: Json
          product_id: string
          revision_id: string
        }
        Update: {
          changed_at?: string
          changed_by?: string
          id?: string
          new_ingredients?: Json
          previous_ingredients?: Json
          product_id?: string
          revision_id?: string
        }
        Relationships: []
      }
      chemical_v3_job_requests: {
        Row: {
          created_at: string
          job_id: string
          user_id: string
          vineyard_id: string | null
        }
        Insert: {
          created_at?: string
          job_id: string
          user_id: string
          vineyard_id?: string | null
        }
        Update: {
          created_at?: string
          job_id?: string
          user_id?: string
          vineyard_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "chemical_v3_job_requests_job_id_fkey"
            columns: ["job_id"]
            isOneToOne: false
            referencedRelation: "chemical_v3_discovery_jobs"
            referencedColumns: ["id"]
          },
        ]
      }
      chemical_v3_product_revisions: {
        Row: {
          active_ingredients: Json
          activity_group_scheme: string | null
          activity_groups: string[]
          core_fields_complete: boolean | null
          country_code: string | null
          created_at: string
          default_rate_options: Json
          discovery_confidence: number | null
          extracted_at: string | null
          extraction_schema_version: number
          front_label_image_path: string | null
          id: string
          label_sha256: string | null
          label_version: string | null
          manufacturer: string
          manufacturer_label_storage_path: string | null
          manufacturer_label_url: string | null
          manufacturer_product_url: string | null
          product_category: string
          product_category_key: string | null
          product_form: string | null
          product_id: string
          product_name: string
          registrant: string | null
          registration_number: string | null
          registration_scheme: string | null
          resistance_classification_state: string
          resistance_group_source: string | null
          review_note: string | null
          review_status: string
          reviewed_at: string | null
          reviewed_by: string | null
          revision_no: number
          source_retrieved_at: string | null
          source_summary: Json
          unresolved_fields: string[]
          updated_at: string
          vineyard_rate_status: string
          vineyard_uses: Json
          warnings: Json
        }
        Insert: {
          active_ingredients?: Json
          activity_group_scheme?: string | null
          activity_groups?: string[]
          core_fields_complete?: boolean | null
          country_code?: string | null
          created_at?: string
          default_rate_options?: Json
          discovery_confidence?: number | null
          extracted_at?: string | null
          extraction_schema_version?: number
          front_label_image_path?: string | null
          id?: string
          label_sha256?: string | null
          label_version?: string | null
          manufacturer?: string
          manufacturer_label_storage_path?: string | null
          manufacturer_label_url?: string | null
          manufacturer_product_url?: string | null
          product_category?: string
          product_category_key?: string | null
          product_form?: string | null
          product_id: string
          product_name?: string
          registrant?: string | null
          registration_number?: string | null
          registration_scheme?: string | null
          resistance_classification_state?: string
          resistance_group_source?: string | null
          review_note?: string | null
          review_status?: string
          reviewed_at?: string | null
          reviewed_by?: string | null
          revision_no: number
          source_retrieved_at?: string | null
          source_summary?: Json
          unresolved_fields?: string[]
          updated_at?: string
          vineyard_rate_status?: string
          vineyard_uses?: Json
          warnings?: Json
        }
        Update: {
          active_ingredients?: Json
          activity_group_scheme?: string | null
          activity_groups?: string[]
          core_fields_complete?: boolean | null
          country_code?: string | null
          created_at?: string
          default_rate_options?: Json
          discovery_confidence?: number | null
          extracted_at?: string | null
          extraction_schema_version?: number
          front_label_image_path?: string | null
          id?: string
          label_sha256?: string | null
          label_version?: string | null
          manufacturer?: string
          manufacturer_label_storage_path?: string | null
          manufacturer_label_url?: string | null
          manufacturer_product_url?: string | null
          product_category?: string
          product_category_key?: string | null
          product_form?: string | null
          product_id?: string
          product_name?: string
          registrant?: string | null
          registration_number?: string | null
          registration_scheme?: string | null
          resistance_classification_state?: string
          resistance_group_source?: string | null
          review_note?: string | null
          review_status?: string
          reviewed_at?: string | null
          reviewed_by?: string | null
          revision_no?: number
          source_retrieved_at?: string | null
          source_summary?: Json
          unresolved_fields?: string[]
          updated_at?: string
          vineyard_rate_status?: string
          vineyard_uses?: Json
          warnings?: Json
        }
        Relationships: [
          {
            foreignKeyName: "chemical_v3_product_revisions_category_fk"
            columns: ["product_category_key"]
            isOneToOne: false
            referencedRelation: "chemical_product_categories"
            referencedColumns: ["category_key"]
          },
          {
            foreignKeyName: "chemical_v3_product_revisions_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "chemical_v3_products"
            referencedColumns: ["id"]
          },
        ]
      }
      chemical_v3_products: {
        Row: {
          approved_at: string | null
          approved_by: string | null
          approved_revision_id: string | null
          country_code: string | null
          created_at: string
          created_by: string | null
          current_revision_id: string | null
          hard_refresh_after: string | null
          id: string
          identity_key: string | null
          last_verified_at: string | null
          soft_refresh_after: string | null
          source_query: string | null
          status: string
          updated_at: string
        }
        Insert: {
          approved_at?: string | null
          approved_by?: string | null
          approved_revision_id?: string | null
          country_code?: string | null
          created_at?: string
          created_by?: string | null
          current_revision_id?: string | null
          hard_refresh_after?: string | null
          id?: string
          identity_key?: string | null
          last_verified_at?: string | null
          soft_refresh_after?: string | null
          source_query?: string | null
          status?: string
          updated_at?: string
        }
        Update: {
          approved_at?: string | null
          approved_by?: string | null
          approved_revision_id?: string | null
          country_code?: string | null
          created_at?: string
          created_by?: string | null
          current_revision_id?: string | null
          hard_refresh_after?: string | null
          id?: string
          identity_key?: string | null
          last_verified_at?: string | null
          soft_refresh_after?: string | null
          source_query?: string | null
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "chemical_v3_products_approved_revision_fk"
            columns: ["approved_revision_id"]
            isOneToOne: false
            referencedRelation: "chemical_v3_product_revisions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chemical_v3_products_approved_revision_fk"
            columns: ["approved_revision_id"]
            isOneToOne: false
            referencedRelation: "saved_chemicals_effective"
            referencedColumns: ["effective_catalogue_revision_id"]
          },
          {
            foreignKeyName: "chemical_v3_products_current_revision_fk"
            columns: ["current_revision_id"]
            isOneToOne: false
            referencedRelation: "chemical_v3_product_revisions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chemical_v3_products_current_revision_fk"
            columns: ["current_revision_id"]
            isOneToOne: false
            referencedRelation: "saved_chemicals_effective"
            referencedColumns: ["effective_catalogue_revision_id"]
          },
        ]
      }
      chemical_v3_rate_options: {
        Row: {
          application_method: string | null
          basis: string
          condition: string | null
          created_at: string
          created_by: string | null
          id: string
          max_value: number | null
          min_value: number | null
          needs_review: boolean
          rate_kind: string
          raw_text: string | null
          revision_id: string
          sort_order: number
          source_document_id: string | null
          source_kind: string
          source_page: number | null
          targets: string[]
          unit: string
          updated_at: string
          value: number | null
        }
        Insert: {
          application_method?: string | null
          basis: string
          condition?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          max_value?: number | null
          min_value?: number | null
          needs_review?: boolean
          rate_kind: string
          raw_text?: string | null
          revision_id: string
          sort_order?: number
          source_document_id?: string | null
          source_kind?: string
          source_page?: number | null
          targets?: string[]
          unit: string
          updated_at?: string
          value?: number | null
        }
        Update: {
          application_method?: string | null
          basis?: string
          condition?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          max_value?: number | null
          min_value?: number | null
          needs_review?: boolean
          rate_kind?: string
          raw_text?: string | null
          revision_id?: string
          sort_order?: number
          source_document_id?: string | null
          source_kind?: string
          source_page?: number | null
          targets?: string[]
          unit?: string
          updated_at?: string
          value?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "chemical_v3_rate_options_revision_id_fkey"
            columns: ["revision_id"]
            isOneToOne: false
            referencedRelation: "chemical_v3_product_revisions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chemical_v3_rate_options_revision_id_fkey"
            columns: ["revision_id"]
            isOneToOne: false
            referencedRelation: "saved_chemicals_effective"
            referencedColumns: ["effective_catalogue_revision_id"]
          },
          {
            foreignKeyName: "chemical_v3_rate_options_source_document_id_fkey"
            columns: ["source_document_id"]
            isOneToOne: false
            referencedRelation: "chemical_v3_documents"
            referencedColumns: ["id"]
          },
        ]
      }
      chemical_v3_review_issues: {
        Row: {
          action_type: string
          created_at: string
          decided_at: string | null
          decided_by: string | null
          detail: string | null
          id: string
          issue_key: string
          options: Json
          resolution_code: string | null
          resolution_note: string | null
          resolution_payload: Json
          revision_id: string
          severity: string
          status: string
          title: string
          updated_at: string
        }
        Insert: {
          action_type?: string
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          detail?: string | null
          id?: string
          issue_key: string
          options?: Json
          resolution_code?: string | null
          resolution_note?: string | null
          resolution_payload?: Json
          revision_id: string
          severity?: string
          status?: string
          title: string
          updated_at?: string
        }
        Update: {
          action_type?: string
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          detail?: string | null
          id?: string
          issue_key?: string
          options?: Json
          resolution_code?: string | null
          resolution_note?: string | null
          resolution_payload?: Json
          revision_id?: string
          severity?: string
          status?: string
          title?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "chemical_v3_review_issues_revision_id_fkey"
            columns: ["revision_id"]
            isOneToOne: false
            referencedRelation: "chemical_v3_product_revisions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chemical_v3_review_issues_revision_id_fkey"
            columns: ["revision_id"]
            isOneToOne: false
            referencedRelation: "saved_chemicals_effective"
            referencedColumns: ["effective_catalogue_revision_id"]
          },
        ]
      }
      chemical_v3_reviews: {
        Row: {
          created_at: string
          decision: string
          id: string
          job_id: string | null
          note: string | null
          product_id: string
          reviewed_by: string
          revision_id: string
        }
        Insert: {
          created_at?: string
          decision: string
          id?: string
          job_id?: string | null
          note?: string | null
          product_id: string
          reviewed_by: string
          revision_id: string
        }
        Update: {
          created_at?: string
          decision?: string
          id?: string
          job_id?: string | null
          note?: string | null
          product_id?: string
          reviewed_by?: string
          revision_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "chemical_v3_reviews_job_id_fkey"
            columns: ["job_id"]
            isOneToOne: false
            referencedRelation: "chemical_v3_discovery_jobs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chemical_v3_reviews_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "chemical_v3_products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chemical_v3_reviews_revision_id_fkey"
            columns: ["revision_id"]
            isOneToOne: false
            referencedRelation: "chemical_v3_product_revisions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chemical_v3_reviews_revision_id_fkey"
            columns: ["revision_id"]
            isOneToOne: false
            referencedRelation: "saved_chemicals_effective"
            referencedColumns: ["effective_catalogue_revision_id"]
          },
        ]
      }
      chemical_web_v2_cache: {
        Row: {
          created_at: string
          expires_at: string
          key: string
          payload: Json
        }
        Insert: {
          created_at?: string
          expires_at: string
          key: string
          payload: Json
        }
        Update: {
          created_at?: string
          expires_at?: string
          key?: string
          payload?: Json
        }
        Relationships: []
      }
      damage_records: {
        Row: {
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          damage_percent: number
          damage_type: string
          date: string
          date_observed: string | null
          deleted_at: string | null
          deleted_by: string | null
          id: string
          latitude: number | null
          longitude: number | null
          notes: string
          operator_name: string | null
          paddock_id: string
          photo_urls: string[] | null
          pin_id: string | null
          polygon_points: Json | null
          row_number: number | null
          severity: string | null
          side: string | null
          status: string
          sync_version: number
          trip_id: string | null
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          vintage: number
        }
        Insert: {
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          damage_percent?: number
          damage_type?: string
          date?: string
          date_observed?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          id?: string
          latitude?: number | null
          longitude?: number | null
          notes?: string
          operator_name?: string | null
          paddock_id: string
          photo_urls?: string[] | null
          pin_id?: string | null
          polygon_points?: Json | null
          row_number?: number | null
          severity?: string | null
          side?: string | null
          status?: string
          sync_version?: number
          trip_id?: string | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
          vintage: number
        }
        Update: {
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          damage_percent?: number
          damage_type?: string
          date?: string
          date_observed?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          id?: string
          latitude?: number | null
          longitude?: number | null
          notes?: string
          operator_name?: string | null
          paddock_id?: string
          photo_urls?: string[] | null
          pin_id?: string | null
          polygon_points?: Json | null
          row_number?: number | null
          severity?: string | null
          side?: string | null
          status?: string
          sync_version?: number
          trip_id?: string | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
          vintage?: number
        }
        Relationships: [
          {
            foreignKeyName: "damage_records_pin_id_fkey"
            columns: ["pin_id"]
            isOneToOne: false
            referencedRelation: "manual_issues_export"
            referencedColumns: ["issue_id"]
          },
          {
            foreignKeyName: "damage_records_pin_id_fkey"
            columns: ["pin_id"]
            isOneToOne: false
            referencedRelation: "pin_placements"
            referencedColumns: ["pin_id"]
          },
          {
            foreignKeyName: "damage_records_pin_id_fkey"
            columns: ["pin_id"]
            isOneToOne: false
            referencedRelation: "pins"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "damage_records_pin_id_fkey"
            columns: ["pin_id"]
            isOneToOne: false
            referencedRelation: "pins_export"
            referencedColumns: ["pin_id"]
          },
          {
            foreignKeyName: "damage_records_pin_id_fkey"
            columns: ["pin_id"]
            isOneToOne: false
            referencedRelation: "v_pin_attachment_preview"
            referencedColumns: ["pin_id"]
          },
          {
            foreignKeyName: "damage_records_trip_id_fkey"
            columns: ["trip_id"]
            isOneToOne: false
            referencedRelation: "trips"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "damage_records_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      disclaimer_acceptances: {
        Row: {
          accepted_at: string
          display_name: string | null
          email: string | null
          id: string
          user_id: string
          version: string
        }
        Insert: {
          accepted_at?: string
          display_name?: string | null
          email?: string | null
          id?: string
          user_id: string
          version: string
        }
        Update: {
          accepted_at?: string
          display_name?: string | null
          email?: string | null
          id?: string
          user_id?: string
          version?: string
        }
        Relationships: [
          {
            foreignKeyName: "disclaimer_acceptances_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      email_delivery_events: {
        Row: {
          actor_user_id: string | null
          bounce_subtype: string | null
          bounce_type: string | null
          bounced_at: string | null
          complained_at: string | null
          created_at: string
          delayed_at: string | null
          delivered_at: string | null
          email_type: string
          error_code: string | null
          failed_at: string | null
          failure_reason: string | null
          id: string
          metadata: Json
          provider: string
          provider_event_at: string | null
          provider_event_id: string | null
          provider_event_type: string | null
          provider_message_id: string | null
          recipient_email: string
          sent_at: string | null
          source_platform: string
          status: string
          suppressed_at: string | null
        }
        Insert: {
          actor_user_id?: string | null
          bounce_subtype?: string | null
          bounce_type?: string | null
          bounced_at?: string | null
          complained_at?: string | null
          created_at?: string
          delayed_at?: string | null
          delivered_at?: string | null
          email_type: string
          error_code?: string | null
          failed_at?: string | null
          failure_reason?: string | null
          id?: string
          metadata?: Json
          provider?: string
          provider_event_at?: string | null
          provider_event_id?: string | null
          provider_event_type?: string | null
          provider_message_id?: string | null
          recipient_email: string
          sent_at?: string | null
          source_platform?: string
          status?: string
          suppressed_at?: string | null
        }
        Update: {
          actor_user_id?: string | null
          bounce_subtype?: string | null
          bounce_type?: string | null
          bounced_at?: string | null
          complained_at?: string | null
          created_at?: string
          delayed_at?: string | null
          delivered_at?: string | null
          email_type?: string
          error_code?: string | null
          failed_at?: string | null
          failure_reason?: string | null
          id?: string
          metadata?: Json
          provider?: string
          provider_event_at?: string | null
          provider_event_id?: string | null
          provider_event_type?: string | null
          provider_message_id?: string | null
          recipient_email?: string
          sent_at?: string | null
          source_platform?: string
          status?: string
          suppressed_at?: string | null
        }
        Relationships: []
      }
      email_webhook_events: {
        Row: {
          delivery_event_id: string | null
          event_created_at: string | null
          event_type: string
          id: string
          processed_at: string | null
          processing_error: string | null
          processing_status: string
          provider: string
          provider_event_id: string
          provider_message_id: string | null
          received_at: string
          safe_payload: Json
        }
        Insert: {
          delivery_event_id?: string | null
          event_created_at?: string | null
          event_type: string
          id?: string
          processed_at?: string | null
          processing_error?: string | null
          processing_status?: string
          provider?: string
          provider_event_id: string
          provider_message_id?: string | null
          received_at?: string
          safe_payload?: Json
        }
        Update: {
          delivery_event_id?: string | null
          event_created_at?: string | null
          event_type?: string
          id?: string
          processed_at?: string | null
          processing_error?: string | null
          processing_status?: string
          provider?: string
          provider_event_id?: string
          provider_message_id?: string | null
          received_at?: string
          safe_payload?: Json
        }
        Relationships: [
          {
            foreignKeyName: "email_webhook_events_delivery_event_id_fkey"
            columns: ["delivery_event_id"]
            isOneToOne: false
            referencedRelation: "email_delivery_events"
            referencedColumns: ["id"]
          },
        ]
      }
      equipment_items: {
        Row: {
          category: string
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          make: string | null
          model: string | null
          name: string
          notes: string
          serial_number: string | null
          sync_version: number
          updated_at: string
          updated_by: string | null
          vin_number: string | null
          vineyard_id: string
        }
        Insert: {
          category?: string
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          make?: string | null
          model?: string | null
          name: string
          notes?: string
          serial_number?: string | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vin_number?: string | null
          vineyard_id: string
        }
        Update: {
          category?: string
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          make?: string | null
          model?: string | null
          name?: string
          notes?: string
          serial_number?: string | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vin_number?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "equipment_items_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      feature_request_comments: {
        Row: {
          body: string
          created_at: string
          created_by: string
          created_by_name: string | null
          feature_request_id: string
          id: string
          updated_at: string
        }
        Insert: {
          body: string
          created_at?: string
          created_by?: string
          created_by_name?: string | null
          feature_request_id: string
          id?: string
          updated_at?: string
        }
        Update: {
          body?: string
          created_at?: string
          created_by?: string
          created_by_name?: string | null
          feature_request_id?: string
          id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "feature_request_comments_feature_request_id_fkey"
            columns: ["feature_request_id"]
            isOneToOne: false
            referencedRelation: "feature_requests"
            referencedColumns: ["id"]
          },
        ]
      }
      feature_request_votes: {
        Row: {
          created_at: string
          feature_request_id: string
          id: string
          user_id: string
        }
        Insert: {
          created_at?: string
          feature_request_id: string
          id?: string
          user_id?: string
        }
        Update: {
          created_at?: string
          feature_request_id?: string
          id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "feature_request_votes_feature_request_id_fkey"
            columns: ["feature_request_id"]
            isOneToOne: false
            referencedRelation: "feature_requests"
            referencedColumns: ["id"]
          },
        ]
      }
      feature_requests: {
        Row: {
          admin_note: string | null
          created_at: string
          created_by: string
          created_by_name: string | null
          details: string | null
          id: string
          is_hidden: boolean
          status: string
          title: string
          updated_at: string
          vineyard_id: string | null
        }
        Insert: {
          admin_note?: string | null
          created_at?: string
          created_by?: string
          created_by_name?: string | null
          details?: string | null
          id?: string
          is_hidden?: boolean
          status?: string
          title: string
          updated_at?: string
          vineyard_id?: string | null
        }
        Update: {
          admin_note?: string | null
          created_at?: string
          created_by?: string
          created_by_name?: string | null
          details?: string | null
          id?: string
          is_hidden?: boolean
          status?: string
          title?: string
          updated_at?: string
          vineyard_id?: string | null
        }
        Relationships: []
      }
      fertigation_application_products: {
        Row: {
          actual_quantity: number | null
          cost_per_unit: number | null
          created_at: string
          fertigation_application_id: string
          id: string
          planned_quantity: number | null
          planned_rate: number | null
          product_category: string | null
          product_form: string | null
          product_name: string
          product_snapshot: Json
          quantity_unit: string | null
          rate_basis: string | null
          rate_unit: string | null
          saved_chemical_id: string | null
          sort_order: number
          updated_at: string
          vineyard_id: string
        }
        Insert: {
          actual_quantity?: number | null
          cost_per_unit?: number | null
          created_at?: string
          fertigation_application_id: string
          id: string
          planned_quantity?: number | null
          planned_rate?: number | null
          product_category?: string | null
          product_form?: string | null
          product_name: string
          product_snapshot?: Json
          quantity_unit?: string | null
          rate_basis?: string | null
          rate_unit?: string | null
          saved_chemical_id?: string | null
          sort_order?: number
          updated_at?: string
          vineyard_id: string
        }
        Update: {
          actual_quantity?: number | null
          cost_per_unit?: number | null
          created_at?: string
          fertigation_application_id?: string
          id?: string
          planned_quantity?: number | null
          planned_rate?: number | null
          product_category?: string | null
          product_form?: string | null
          product_name?: string
          product_snapshot?: Json
          quantity_unit?: string | null
          rate_basis?: string | null
          rate_unit?: string | null
          saved_chemical_id?: string | null
          sort_order?: number
          updated_at?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fertigation_application_product_fertigation_application_id_fkey"
            columns: ["fertigation_application_id"]
            isOneToOne: false
            referencedRelation: "fertigation_applications"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fertigation_application_products_saved_chemical_id_fkey"
            columns: ["saved_chemical_id"]
            isOneToOne: false
            referencedRelation: "saved_chemical_intelligence_audit"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fertigation_application_products_saved_chemical_id_fkey"
            columns: ["saved_chemical_id"]
            isOneToOne: false
            referencedRelation: "saved_chemicals"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fertigation_application_products_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      fertigation_applications: {
        Row: {
          created_at: string
          created_by: string | null
          growth_stage_code: string | null
          id: string
          irrigation_session_id: string
          notes: string | null
          program_step_id: string | null
          program_step_name: string | null
          reversal_reason: string | null
          reversed_at: string | null
          reversed_by: string | null
          status: string
          updated_at: string
          updated_by: string | null
          vineyard_id: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          growth_stage_code?: string | null
          id: string
          irrigation_session_id: string
          notes?: string | null
          program_step_id?: string | null
          program_step_name?: string | null
          reversal_reason?: string | null
          reversed_at?: string | null
          reversed_by?: string | null
          status?: string
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          growth_stage_code?: string | null
          id?: string
          irrigation_session_id?: string
          notes?: string | null
          program_step_id?: string | null
          program_step_name?: string | null
          reversal_reason?: string | null
          reversed_at?: string | null
          reversed_by?: string | null
          status?: string
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fertigation_applications_irrigation_session_id_fkey"
            columns: ["irrigation_session_id"]
            isOneToOne: false
            referencedRelation: "irrigation_sessions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fertigation_applications_program_step_id_fkey"
            columns: ["program_step_id"]
            isOneToOne: false
            referencedRelation: "spray_jobs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fertigation_applications_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      fertiliser_record_allocations: {
        Row: {
          allocated_cost: number | null
          application_rate: number
          area_ha: number
          created_at: string
          fertiliser_record_id: string
          id: string
          paddock_id: string
          product_required: number
          updated_at: string
          vine_count: number
          vineyard_id: string
        }
        Insert: {
          allocated_cost?: number | null
          application_rate?: number
          area_ha?: number
          created_at?: string
          fertiliser_record_id: string
          id: string
          paddock_id: string
          product_required?: number
          updated_at?: string
          vine_count?: number
          vineyard_id: string
        }
        Update: {
          allocated_cost?: number | null
          application_rate?: number
          area_ha?: number
          created_at?: string
          fertiliser_record_id?: string
          id?: string
          paddock_id?: string
          product_required?: number
          updated_at?: string
          vine_count?: number
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fertiliser_record_allocations_fertiliser_record_id_fkey"
            columns: ["fertiliser_record_id"]
            isOneToOne: false
            referencedRelation: "fertiliser_records"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fertiliser_record_allocations_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      fertiliser_records: {
        Row: {
          analysis_basis: string | null
          application_date: string
          application_rate: number
          application_rate_unit: string
          block_names: string[]
          calculation_mode: string
          client_updated_at: string | null
          concentration_basis: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          estimated_product_cost: number | null
          form: string
          id: string
          labour_cost: number | null
          machinery_cost: number | null
          notes: string
          nutrient_contract_version: number | null
          nutrient_declared_as: string | null
          nutrient_display_name: string | null
          nutrient_key: string | null
          nutrient_percent: number | null
          nutrient_percent_source: string | null
          pack_count: number | null
          pack_size: number | null
          product_analysis_snapshot: Json | null
          product_density_kg_per_l: number | null
          product_density_reference: string | null
          product_density_source: string | null
          product_id: string | null
          product_name: string
          product_unit: string
          record_status: string
          sync_version: number
          target_rate: number | null
          target_rate_unit: string | null
          total_area_ha: number
          total_job_cost: number | null
          total_product_required: number
          total_vines: number
          updated_at: string
          updated_by: string | null
          vine_count_basis: string | null
          vineyard_id: string
        }
        Insert: {
          analysis_basis?: string | null
          application_date?: string
          application_rate?: number
          application_rate_unit?: string
          block_names?: string[]
          calculation_mode?: string
          client_updated_at?: string | null
          concentration_basis?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          estimated_product_cost?: number | null
          form?: string
          id: string
          labour_cost?: number | null
          machinery_cost?: number | null
          notes?: string
          nutrient_contract_version?: number | null
          nutrient_declared_as?: string | null
          nutrient_display_name?: string | null
          nutrient_key?: string | null
          nutrient_percent?: number | null
          nutrient_percent_source?: string | null
          pack_count?: number | null
          pack_size?: number | null
          product_analysis_snapshot?: Json | null
          product_density_kg_per_l?: number | null
          product_density_reference?: string | null
          product_density_source?: string | null
          product_id?: string | null
          product_name?: string
          product_unit?: string
          record_status?: string
          sync_version?: number
          target_rate?: number | null
          target_rate_unit?: string | null
          total_area_ha?: number
          total_job_cost?: number | null
          total_product_required?: number
          total_vines?: number
          updated_at?: string
          updated_by?: string | null
          vine_count_basis?: string | null
          vineyard_id: string
        }
        Update: {
          analysis_basis?: string | null
          application_date?: string
          application_rate?: number
          application_rate_unit?: string
          block_names?: string[]
          calculation_mode?: string
          client_updated_at?: string | null
          concentration_basis?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          estimated_product_cost?: number | null
          form?: string
          id?: string
          labour_cost?: number | null
          machinery_cost?: number | null
          notes?: string
          nutrient_contract_version?: number | null
          nutrient_declared_as?: string | null
          nutrient_display_name?: string | null
          nutrient_key?: string | null
          nutrient_percent?: number | null
          nutrient_percent_source?: string | null
          pack_count?: number | null
          pack_size?: number | null
          product_analysis_snapshot?: Json | null
          product_density_kg_per_l?: number | null
          product_density_reference?: string | null
          product_density_source?: string | null
          product_id?: string | null
          product_name?: string
          product_unit?: string
          record_status?: string
          sync_version?: number
          target_rate?: number | null
          target_rate_unit?: string | null
          total_area_ha?: number
          total_job_cost?: number | null
          total_product_required?: number
          total_vines?: number
          updated_at?: string
          updated_by?: string | null
          vine_count_basis?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fertiliser_records_product_saved_chemical_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "saved_chemical_intelligence_audit"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fertiliser_records_product_saved_chemical_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "saved_chemicals"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fertiliser_records_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      fuel_purchases: {
        Row: {
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          date: string
          deleted_at: string | null
          id: string
          sync_version: number
          total_cost: number
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          volume_litres: number
        }
        Insert: {
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          date?: string
          deleted_at?: string | null
          id?: string
          sync_version?: number
          total_cost?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
          volume_litres?: number
        }
        Update: {
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          date?: string
          deleted_at?: string | null
          id?: string
          sync_version?: number
          total_cost?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
          volume_litres?: number
        }
        Relationships: [
          {
            foreignKeyName: "fuel_purchases_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      grape_allocation_blocks: {
        Row: {
          allocation_id: string
          created_at: string
          id: string
          paddock_id: string
          paddock_name: string
          quantity_tonnes: number | null
          updated_at: string
          vineyard_id: string
        }
        Insert: {
          allocation_id: string
          created_at?: string
          id?: string
          paddock_id: string
          paddock_name?: string
          quantity_tonnes?: number | null
          updated_at?: string
          vineyard_id: string
        }
        Update: {
          allocation_id?: string
          created_at?: string
          id?: string
          paddock_id?: string
          paddock_name?: string
          quantity_tonnes?: number | null
          updated_at?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "grape_allocation_blocks_allocation_id_fkey"
            columns: ["allocation_id"]
            isOneToOne: false
            referencedRelation: "grape_allocations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "grape_allocation_blocks_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      grape_allocation_financials: {
        Row: {
          allocation_id: string
          price_per_tonne: number | null
          updated_at: string
          updated_by: string | null
          vineyard_id: string
        }
        Insert: {
          allocation_id: string
          price_per_tonne?: number | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
        }
        Update: {
          allocation_id?: string
          price_per_tonne?: number | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "grape_allocation_financials_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      grape_allocations: {
        Row: {
          allocation_type: string
          client_updated_at: string | null
          contact_address: string | null
          contact_email: string | null
          contact_name: string | null
          contact_phone: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          destination_name: string | null
          external_id: string | null
          id: string
          integration_api_key_id: string | null
          integration_client_id: string | null
          notes: string | null
          origin: string
          price_per_tonne: number | null
          purchaser_id: string | null
          purchaser_name: string | null
          quantity_tonnes: number
          sync_version: number
          updated_at: string
          updated_by: string | null
          updated_by_integration_client_id: string | null
          variety_id: string | null
          variety_key: string | null
          variety_name: string
          vineyard_id: string
          vintage: number
        }
        Insert: {
          allocation_type: string
          client_updated_at?: string | null
          contact_address?: string | null
          contact_email?: string | null
          contact_name?: string | null
          contact_phone?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          destination_name?: string | null
          external_id?: string | null
          id?: string
          integration_api_key_id?: string | null
          integration_client_id?: string | null
          notes?: string | null
          origin?: string
          price_per_tonne?: number | null
          purchaser_id?: string | null
          purchaser_name?: string | null
          quantity_tonnes: number
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          updated_by_integration_client_id?: string | null
          variety_id?: string | null
          variety_key?: string | null
          variety_name: string
          vineyard_id: string
          vintage: number
        }
        Update: {
          allocation_type?: string
          client_updated_at?: string | null
          contact_address?: string | null
          contact_email?: string | null
          contact_name?: string | null
          contact_phone?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          destination_name?: string | null
          external_id?: string | null
          id?: string
          integration_api_key_id?: string | null
          integration_client_id?: string | null
          notes?: string | null
          origin?: string
          price_per_tonne?: number | null
          purchaser_id?: string | null
          purchaser_name?: string | null
          quantity_tonnes?: number
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          updated_by_integration_client_id?: string | null
          variety_id?: string | null
          variety_key?: string | null
          variety_name?: string
          vineyard_id?: string
          vintage?: number
        }
        Relationships: [
          {
            foreignKeyName: "grape_allocations_purchaser_id_fkey"
            columns: ["purchaser_id"]
            isOneToOne: false
            referencedRelation: "grape_purchasers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "grape_allocations_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      grape_clone_catalog: {
        Row: {
          aliases: Json
          clone_code: string
          created_at: string
          display_name: string
          is_active: boolean
          is_builtin: boolean
          key: string
          selection_system: string | null
          source_country: string | null
          source_reference: string | null
          updated_at: string
          variety_key: string
        }
        Insert: {
          aliases?: Json
          clone_code: string
          created_at?: string
          display_name: string
          is_active?: boolean
          is_builtin?: boolean
          key: string
          selection_system?: string | null
          source_country?: string | null
          source_reference?: string | null
          updated_at?: string
          variety_key: string
        }
        Update: {
          aliases?: Json
          clone_code?: string
          created_at?: string
          display_name?: string
          is_active?: boolean
          is_builtin?: boolean
          key?: string
          selection_system?: string | null
          source_country?: string | null
          source_reference?: string | null
          updated_at?: string
          variety_key?: string
        }
        Relationships: []
      }
      grape_purchasers: {
        Row: {
          client_updated_at: string | null
          contact_address: string | null
          contact_email: string | null
          contact_name: string | null
          contact_phone: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          external_id: string | null
          id: string
          integration_api_key_id: string | null
          integration_client_id: string | null
          origin: string
          sync_version: number
          updated_at: string
          updated_by: string | null
          updated_by_integration_client_id: string | null
          vineyard_id: string
          winery_name: string
        }
        Insert: {
          client_updated_at?: string | null
          contact_address?: string | null
          contact_email?: string | null
          contact_name?: string | null
          contact_phone?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          external_id?: string | null
          id?: string
          integration_api_key_id?: string | null
          integration_client_id?: string | null
          origin?: string
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          updated_by_integration_client_id?: string | null
          vineyard_id: string
          winery_name: string
        }
        Update: {
          client_updated_at?: string | null
          contact_address?: string | null
          contact_email?: string | null
          contact_name?: string | null
          contact_phone?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          external_id?: string | null
          id?: string
          integration_api_key_id?: string | null
          integration_client_id?: string | null
          origin?: string
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          updated_by_integration_client_id?: string | null
          vineyard_id?: string
          winery_name?: string
        }
        Relationships: [
          {
            foreignKeyName: "grape_purchasers_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      grape_variety_catalog: {
        Row: {
          aliases: Json
          canonical_name: string
          created_at: string
          display_name: string
          is_active: boolean
          is_builtin: boolean
          key: string
          optimal_gdd: number | null
          updated_at: string
        }
        Insert: {
          aliases?: Json
          canonical_name: string
          created_at?: string
          display_name: string
          is_active?: boolean
          is_builtin?: boolean
          key: string
          optimal_gdd?: number | null
          updated_at?: string
        }
        Update: {
          aliases?: Json
          canonical_name?: string
          created_at?: string
          display_name?: string
          is_active?: boolean
          is_builtin?: boolean
          key?: string
          optimal_gdd?: number | null
          updated_at?: string
        }
        Relationships: []
      }
      growth_stage_records: {
        Row: {
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          external_id: string | null
          id: string
          integration_api_key_id: string | null
          integration_client_id: string | null
          latitude: number | null
          longitude: number | null
          notes: string | null
          observed_at: string
          origin: string
          paddock_id: string | null
          photo_paths: string[]
          pin_id: string | null
          recorded_by_name: string | null
          row_number: number | null
          side: string | null
          stage_code: string
          stage_label: string | null
          sync_version: number
          updated_at: string
          updated_by: string | null
          updated_by_integration_client_id: string | null
          variety: string | null
          variety_id: string | null
          vineyard_id: string
        }
        Insert: {
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          external_id?: string | null
          id?: string
          integration_api_key_id?: string | null
          integration_client_id?: string | null
          latitude?: number | null
          longitude?: number | null
          notes?: string | null
          observed_at?: string
          origin?: string
          paddock_id?: string | null
          photo_paths?: string[]
          pin_id?: string | null
          recorded_by_name?: string | null
          row_number?: number | null
          side?: string | null
          stage_code: string
          stage_label?: string | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          updated_by_integration_client_id?: string | null
          variety?: string | null
          variety_id?: string | null
          vineyard_id: string
        }
        Update: {
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          external_id?: string | null
          id?: string
          integration_api_key_id?: string | null
          integration_client_id?: string | null
          latitude?: number | null
          longitude?: number | null
          notes?: string | null
          observed_at?: string
          origin?: string
          paddock_id?: string | null
          photo_paths?: string[]
          pin_id?: string | null
          recorded_by_name?: string | null
          row_number?: number | null
          side?: string | null
          stage_code?: string
          stage_label?: string | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          updated_by_integration_client_id?: string | null
          variety?: string | null
          variety_id?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "growth_stage_records_integration_api_key_id_fkey"
            columns: ["integration_api_key_id"]
            isOneToOne: false
            referencedRelation: "integration_api_keys"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "growth_stage_records_integration_client_id_fkey"
            columns: ["integration_client_id"]
            isOneToOne: false
            referencedRelation: "integration_clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "growth_stage_records_paddock_id_fkey"
            columns: ["paddock_id"]
            isOneToOne: false
            referencedRelation: "paddocks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "growth_stage_records_pin_id_fkey"
            columns: ["pin_id"]
            isOneToOne: false
            referencedRelation: "manual_issues_export"
            referencedColumns: ["issue_id"]
          },
          {
            foreignKeyName: "growth_stage_records_pin_id_fkey"
            columns: ["pin_id"]
            isOneToOne: false
            referencedRelation: "pin_placements"
            referencedColumns: ["pin_id"]
          },
          {
            foreignKeyName: "growth_stage_records_pin_id_fkey"
            columns: ["pin_id"]
            isOneToOne: false
            referencedRelation: "pins"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "growth_stage_records_pin_id_fkey"
            columns: ["pin_id"]
            isOneToOne: false
            referencedRelation: "pins_export"
            referencedColumns: ["pin_id"]
          },
          {
            foreignKeyName: "growth_stage_records_pin_id_fkey"
            columns: ["pin_id"]
            isOneToOne: false
            referencedRelation: "v_pin_attachment_preview"
            referencedColumns: ["pin_id"]
          },
          {
            foreignKeyName: "growth_stage_records_updated_by_integration_client_id_fkey"
            columns: ["updated_by_integration_client_id"]
            isOneToOne: false
            referencedRelation: "integration_clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "growth_stage_records_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      historical_yield_records: {
        Row: {
          archived_at: string
          block_results: Json | null
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          external_id: string | null
          id: string
          integration_api_key_id: string | null
          integration_client_id: string | null
          notes: string
          origin: string
          season: string
          sync_version: number
          total_area_hectares: number
          total_yield_tonnes: number
          updated_at: string
          updated_by: string | null
          updated_by_integration_client_id: string | null
          vineyard_id: string
          year: number
        }
        Insert: {
          archived_at?: string
          block_results?: Json | null
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          external_id?: string | null
          id?: string
          integration_api_key_id?: string | null
          integration_client_id?: string | null
          notes?: string
          origin?: string
          season?: string
          sync_version?: number
          total_area_hectares?: number
          total_yield_tonnes?: number
          updated_at?: string
          updated_by?: string | null
          updated_by_integration_client_id?: string | null
          vineyard_id: string
          year?: number
        }
        Update: {
          archived_at?: string
          block_results?: Json | null
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          external_id?: string | null
          id?: string
          integration_api_key_id?: string | null
          integration_client_id?: string | null
          notes?: string
          origin?: string
          season?: string
          sync_version?: number
          total_area_hectares?: number
          total_yield_tonnes?: number
          updated_at?: string
          updated_by?: string | null
          updated_by_integration_client_id?: string | null
          vineyard_id?: string
          year?: number
        }
        Relationships: [
          {
            foreignKeyName: "historical_yield_records_integration_api_key_id_fkey"
            columns: ["integration_api_key_id"]
            isOneToOne: false
            referencedRelation: "integration_api_keys"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "historical_yield_records_integration_client_id_fkey"
            columns: ["integration_client_id"]
            isOneToOne: false
            referencedRelation: "integration_clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "historical_yield_records_updated_by_integration_client_id_fkey"
            columns: ["updated_by_integration_client_id"]
            isOneToOne: false
            referencedRelation: "integration_clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "historical_yield_records_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      integration_api_keys: {
        Row: {
          created_at: string
          created_by: string
          environment: string
          expires_at: string | null
          id: string
          integration_client_id: string
          key_hash: string
          key_prefix: string
          last_used_at: string | null
          name: string | null
          revoked_at: string | null
        }
        Insert: {
          created_at?: string
          created_by: string
          environment?: string
          expires_at?: string | null
          id?: string
          integration_client_id: string
          key_hash: string
          key_prefix: string
          last_used_at?: string | null
          name?: string | null
          revoked_at?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string
          environment?: string
          expires_at?: string | null
          id?: string
          integration_client_id?: string
          key_hash?: string
          key_prefix?: string
          last_used_at?: string | null
          name?: string | null
          revoked_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "integration_api_keys_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "integration_api_keys_integration_client_id_fkey"
            columns: ["integration_client_id"]
            isOneToOne: false
            referencedRelation: "integration_clients"
            referencedColumns: ["id"]
          },
        ]
      }
      integration_api_requests: {
        Row: {
          api_key_id: string | null
          created_at: string
          duration_ms: number | null
          error_code: string | null
          id: string
          integration_client_id: string | null
          method: string
          path: string
          request_id: string | null
          status_code: number
          vineyard_id: string | null
        }
        Insert: {
          api_key_id?: string | null
          created_at?: string
          duration_ms?: number | null
          error_code?: string | null
          id?: string
          integration_client_id?: string | null
          method: string
          path: string
          request_id?: string | null
          status_code: number
          vineyard_id?: string | null
        }
        Update: {
          api_key_id?: string | null
          created_at?: string
          duration_ms?: number | null
          error_code?: string | null
          id?: string
          integration_client_id?: string | null
          method?: string
          path?: string
          request_id?: string | null
          status_code?: number
          vineyard_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "integration_api_requests_api_key_id_fkey"
            columns: ["api_key_id"]
            isOneToOne: false
            referencedRelation: "integration_api_keys"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "integration_api_requests_integration_client_id_fkey"
            columns: ["integration_client_id"]
            isOneToOne: false
            referencedRelation: "integration_clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "integration_api_requests_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      integration_audit_log: {
        Row: {
          action: string
          actor_user_id: string | null
          created_at: string
          id: string
          integration_client_id: string
          metadata: Json
          vineyard_id: string | null
        }
        Insert: {
          action: string
          actor_user_id?: string | null
          created_at?: string
          id?: string
          integration_client_id: string
          metadata?: Json
          vineyard_id?: string | null
        }
        Update: {
          action?: string
          actor_user_id?: string | null
          created_at?: string
          id?: string
          integration_client_id?: string
          metadata?: Json
          vineyard_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "integration_audit_log_actor_user_id_fkey"
            columns: ["actor_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "integration_audit_log_integration_client_id_fkey"
            columns: ["integration_client_id"]
            isOneToOne: false
            referencedRelation: "integration_clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "integration_audit_log_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      integration_client_scopes: {
        Row: {
          granted_at: string
          granted_by: string
          id: string
          integration_client_id: string
          revoked_at: string | null
          scope: string
        }
        Insert: {
          granted_at?: string
          granted_by: string
          id?: string
          integration_client_id: string
          revoked_at?: string | null
          scope: string
        }
        Update: {
          granted_at?: string
          granted_by?: string
          id?: string
          integration_client_id?: string
          revoked_at?: string | null
          scope?: string
        }
        Relationships: [
          {
            foreignKeyName: "integration_client_scopes_granted_by_fkey"
            columns: ["granted_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "integration_client_scopes_integration_client_id_fkey"
            columns: ["integration_client_id"]
            isOneToOne: false
            referencedRelation: "integration_clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "integration_client_scopes_scope_fkey"
            columns: ["scope"]
            isOneToOne: false
            referencedRelation: "integration_scope_catalog"
            referencedColumns: ["scope"]
          },
        ]
      }
      integration_client_vineyards: {
        Row: {
          granted_at: string
          granted_by: string
          id: string
          integration_client_id: string
          revoked_at: string | null
          vineyard_id: string
        }
        Insert: {
          granted_at?: string
          granted_by: string
          id?: string
          integration_client_id: string
          revoked_at?: string | null
          vineyard_id: string
        }
        Update: {
          granted_at?: string
          granted_by?: string
          id?: string
          integration_client_id?: string
          revoked_at?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "integration_client_vineyards_granted_by_fkey"
            columns: ["granted_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "integration_client_vineyards_integration_client_id_fkey"
            columns: ["integration_client_id"]
            isOneToOne: false
            referencedRelation: "integration_clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "integration_client_vineyards_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      integration_clients: {
        Row: {
          created_at: string
          created_by: string
          description: string | null
          id: string
          integration_type: string
          name: string
          owner_user_id: string
          paused_at: string | null
          revoked_at: string | null
          status: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          created_by: string
          description?: string | null
          id?: string
          integration_type: string
          name: string
          owner_user_id: string
          paused_at?: string | null
          revoked_at?: string | null
          status?: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          created_by?: string
          description?: string | null
          id?: string
          integration_type?: string
          name?: string
          owner_user_id?: string
          paused_at?: string | null
          revoked_at?: string | null
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "integration_clients_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "integration_clients_owner_user_id_fkey"
            columns: ["owner_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      integration_environment_cache: {
        Row: {
          fetched_at: string
          id: string
          kind: string
          payload: Json
          vineyard_id: string
        }
        Insert: {
          fetched_at?: string
          id?: string
          kind: string
          payload: Json
          vineyard_id: string
        }
        Update: {
          fetched_at?: string
          id?: string
          kind?: string
          payload?: Json
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "integration_environment_cache_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      integration_events: {
        Row: {
          api_version: string
          created_at: string
          dedup_key: string | null
          event_type: string
          id: string
          occurred_at: string
          payload: Json
          public_id: string
          resource_id: string
          resource_type: string
          source: string | null
          vineyard_id: string | null
        }
        Insert: {
          api_version?: string
          created_at?: string
          dedup_key?: string | null
          event_type: string
          id?: string
          occurred_at?: string
          payload?: Json
          public_id?: string
          resource_id: string
          resource_type: string
          source?: string | null
          vineyard_id?: string | null
        }
        Update: {
          api_version?: string
          created_at?: string
          dedup_key?: string | null
          event_type?: string
          id?: string
          occurred_at?: string
          payload?: Json
          public_id?: string
          resource_id?: string
          resource_type?: string
          source?: string | null
          vineyard_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "integration_events_event_type_fkey"
            columns: ["event_type"]
            isOneToOne: false
            referencedRelation: "integration_webhook_event_catalog"
            referencedColumns: ["event"]
          },
          {
            foreignKeyName: "integration_events_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      integration_idempotency_keys: {
        Row: {
          completed_at: string | null
          created_at: string
          id: string
          idempotency_key: string
          integration_client_id: string
          operation: string
          request_hash: string
          resource_id: string | null
          resource_type: string | null
          response_body: Json | null
          status_code: number | null
        }
        Insert: {
          completed_at?: string | null
          created_at?: string
          id?: string
          idempotency_key: string
          integration_client_id: string
          operation: string
          request_hash: string
          resource_id?: string | null
          resource_type?: string | null
          response_body?: Json | null
          status_code?: number | null
        }
        Update: {
          completed_at?: string | null
          created_at?: string
          id?: string
          idempotency_key?: string
          integration_client_id?: string
          operation?: string
          request_hash?: string
          resource_id?: string | null
          resource_type?: string | null
          response_body?: Json | null
          status_code?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "integration_idempotency_keys_integration_client_id_fkey"
            columns: ["integration_client_id"]
            isOneToOne: false
            referencedRelation: "integration_clients"
            referencedColumns: ["id"]
          },
        ]
      }
      integration_rate_limit_counters: {
        Row: {
          api_key_id: string
          request_count: number
          window_start: string
        }
        Insert: {
          api_key_id: string
          request_count?: number
          window_start: string
        }
        Update: {
          api_key_id?: string
          request_count?: number
          window_start?: string
        }
        Relationships: [
          {
            foreignKeyName: "integration_rate_limit_counters_api_key_id_fkey"
            columns: ["api_key_id"]
            isOneToOne: false
            referencedRelation: "integration_api_keys"
            referencedColumns: ["id"]
          },
        ]
      }
      integration_scope_catalog: {
        Row: {
          access: string
          created_at: string
          description: string
          is_sensitive: boolean
          module: string
          scope: string
        }
        Insert: {
          access: string
          created_at?: string
          description: string
          is_sensitive?: boolean
          module: string
          scope: string
        }
        Update: {
          access?: string
          created_at?: string
          description?: string
          is_sensitive?: boolean
          module?: string
          scope?: string
        }
        Relationships: []
      }
      integration_webhook_event_catalog: {
        Row: {
          created_at: string
          description: string
          event: string
          is_system: boolean
          module: string
        }
        Insert: {
          created_at?: string
          description: string
          event: string
          is_system?: boolean
          module: string
        }
        Update: {
          created_at?: string
          description?: string
          event?: string
          is_system?: boolean
          module?: string
        }
        Relationships: []
      }
      invitations: {
        Row: {
          created_at: string
          email: string
          expires_at: string | null
          id: string
          invited_by: string | null
          role: string
          status: string
          updated_at: string
          vineyard_id: string
          worker_type_id: string | null
        }
        Insert: {
          created_at?: string
          email: string
          expires_at?: string | null
          id?: string
          invited_by?: string | null
          role: string
          status?: string
          updated_at?: string
          vineyard_id: string
          worker_type_id?: string | null
        }
        Update: {
          created_at?: string
          email?: string
          expires_at?: string | null
          id?: string
          invited_by?: string | null
          role?: string
          status?: string
          updated_at?: string
          vineyard_id?: string
          worker_type_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "invitations_invited_by_fkey"
            columns: ["invited_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invitations_operator_category_id_fkey"
            columns: ["worker_type_id"]
            isOneToOne: false
            referencedRelation: "operator_categories"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invitations_operator_category_id_fkey"
            columns: ["worker_type_id"]
            isOneToOne: false
            referencedRelation: "worker_types"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invitations_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      irrigation_audit: {
        Row: {
          action: string
          created_at: string
          entity_id: string
          entity_type: string
          id: string
          new_values: Json | null
          old_values: Json | null
          user_id: string | null
          vineyard_id: string
        }
        Insert: {
          action: string
          created_at?: string
          entity_id: string
          entity_type: string
          id?: string
          new_values?: Json | null
          old_values?: Json | null
          user_id?: string | null
          vineyard_id: string
        }
        Update: {
          action?: string
          created_at?: string
          entity_id?: string
          entity_type?: string
          id?: string
          new_values?: Json | null
          old_values?: Json | null
          user_id?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "irrigation_audit_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      irrigation_controller_valve_mappings: {
        Row: {
          created_at: string
          created_by: string | null
          external_controller_key: string
          external_controller_name: string | null
          external_station_code: string | null
          external_valve_name: string
          external_valve_number: number | null
          first_seen_at: string
          id: string
          irrigation_system_id: string | null
          irrigation_valve_id: string | null
          is_active: boolean
          is_ignored: boolean
          last_seen_at: string
          last_successfully_imported_at: string | null
          mapping_source: string
          provider: string
          updated_at: string
          updated_by: string | null
          vineyard_id: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          external_controller_key?: string
          external_controller_name?: string | null
          external_station_code?: string | null
          external_valve_name: string
          external_valve_number?: number | null
          first_seen_at?: string
          id?: string
          irrigation_system_id?: string | null
          irrigation_valve_id?: string | null
          is_active?: boolean
          is_ignored?: boolean
          last_seen_at?: string
          last_successfully_imported_at?: string | null
          mapping_source?: string
          provider: string
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          external_controller_key?: string
          external_controller_name?: string | null
          external_station_code?: string | null
          external_valve_name?: string
          external_valve_number?: number | null
          first_seen_at?: string
          id?: string
          irrigation_system_id?: string | null
          irrigation_valve_id?: string | null
          is_active?: boolean
          is_ignored?: boolean
          last_seen_at?: string
          last_successfully_imported_at?: string | null
          mapping_source?: string
          provider?: string
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "irrigation_controller_valve_mappings_irrigation_system_id_fkey"
            columns: ["irrigation_system_id"]
            isOneToOne: false
            referencedRelation: "irrigation_systems"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "irrigation_controller_valve_mappings_irrigation_valve_id_fkey"
            columns: ["irrigation_valve_id"]
            isOneToOne: false
            referencedRelation: "irrigation_valves"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "irrigation_controller_valve_mappings_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      irrigation_import_batches: {
        Row: {
          completed_at: string | null
          created_at: string
          created_by: string | null
          duplicate_rows: number
          error_rows: number
          exclude_test_programs: boolean
          external_controller_key: string
          file_hash: string
          file_name: string
          file_size: number | null
          id: string
          ignored_rows: number
          imported_sessions: number
          provider: string
          reprocess_of_batch_id: string | null
          reversed_at: string | null
          reversed_by: string | null
          review_rows: number
          source_unit_name: string | null
          status: string
          threshold_litres: number
          timezone: string | null
          total_rows: number
          valid_rows: number
          vineyard_id: string
          volume_comparison: string
          worksheet_name: string | null
        }
        Insert: {
          completed_at?: string | null
          created_at?: string
          created_by?: string | null
          duplicate_rows?: number
          error_rows?: number
          exclude_test_programs?: boolean
          external_controller_key?: string
          file_hash: string
          file_name: string
          file_size?: number | null
          id?: string
          ignored_rows?: number
          imported_sessions?: number
          provider: string
          reprocess_of_batch_id?: string | null
          reversed_at?: string | null
          reversed_by?: string | null
          review_rows?: number
          source_unit_name?: string | null
          status?: string
          threshold_litres?: number
          timezone?: string | null
          total_rows?: number
          valid_rows?: number
          vineyard_id: string
          volume_comparison?: string
          worksheet_name?: string | null
        }
        Update: {
          completed_at?: string | null
          created_at?: string
          created_by?: string | null
          duplicate_rows?: number
          error_rows?: number
          exclude_test_programs?: boolean
          external_controller_key?: string
          file_hash?: string
          file_name?: string
          file_size?: number | null
          id?: string
          ignored_rows?: number
          imported_sessions?: number
          provider?: string
          reprocess_of_batch_id?: string | null
          reversed_at?: string | null
          reversed_by?: string | null
          review_rows?: number
          source_unit_name?: string | null
          status?: string
          threshold_litres?: number
          timezone?: string | null
          total_rows?: number
          valid_rows?: number
          vineyard_id?: string
          volume_comparison?: string
          worksheet_name?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "irrigation_import_batches_reprocess_of_batch_id_fkey"
            columns: ["reprocess_of_batch_id"]
            isOneToOne: false
            referencedRelation: "irrigation_import_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "irrigation_import_batches_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      irrigation_import_provider_settings: {
        Row: {
          created_at: string
          created_by: string | null
          exclude_test_programs: boolean
          external_controller_key: string
          external_controller_name: string | null
          id: string
          is_active: boolean
          last_imported_at: string | null
          minimum_volume_litres: number
          provider: string
          timezone: string | null
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          volume_comparison: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          exclude_test_programs?: boolean
          external_controller_key?: string
          external_controller_name?: string | null
          id?: string
          is_active?: boolean
          last_imported_at?: string | null
          minimum_volume_litres?: number
          provider: string
          timezone?: string | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
          volume_comparison?: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          exclude_test_programs?: boolean
          external_controller_key?: string
          external_controller_name?: string | null
          id?: string
          is_active?: boolean
          last_imported_at?: string | null
          minimum_volume_litres?: number
          provider?: string
          timezone?: string | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
          volume_comparison?: string
        }
        Relationships: [
          {
            foreignKeyName: "irrigation_import_provider_settings_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      irrigation_import_rows: {
        Row: {
          additional_reason_codes: Json
          batch_id: string
          classification: string | null
          created_at: string
          created_session_id: string | null
          duplicate_reference: string | null
          duplicate_status: string
          event_fingerprint: string | null
          expected_water_litres: number | null
          external_station_code: string | null
          external_valve_label: string | null
          external_valve_name: string | null
          external_valve_number: number | null
          id: string
          is_reversed: boolean
          matched_mapping_id: string | null
          matched_valve_id: string | null
          original_flow_unit: string | null
          original_flow_value: number | null
          original_water_unit: string | null
          original_water_value: number | null
          override_at: string | null
          override_by: string | null
          override_reason: string | null
          override_test: boolean
          override_threshold: boolean
          parsed_date: string | null
          parsed_duration_seconds: number | null
          parsed_end_time: string | null
          parsed_flow_litres_per_hour: number | null
          parsed_start_time: string | null
          parsed_water_litres: number | null
          primary_exclusion_reason: string | null
          program_name: string | null
          provider: string
          raw_payload: Json
          raw_row_hash: string
          source_comment: string | null
          source_row_number: number
          validation_errors: Json
          validation_status: string
          validation_warnings: Json
          vineyard_id: string
          water_flow_reconciliation: string | null
        }
        Insert: {
          additional_reason_codes?: Json
          batch_id: string
          classification?: string | null
          created_at?: string
          created_session_id?: string | null
          duplicate_reference?: string | null
          duplicate_status?: string
          event_fingerprint?: string | null
          expected_water_litres?: number | null
          external_station_code?: string | null
          external_valve_label?: string | null
          external_valve_name?: string | null
          external_valve_number?: number | null
          id?: string
          is_reversed?: boolean
          matched_mapping_id?: string | null
          matched_valve_id?: string | null
          original_flow_unit?: string | null
          original_flow_value?: number | null
          original_water_unit?: string | null
          original_water_value?: number | null
          override_at?: string | null
          override_by?: string | null
          override_reason?: string | null
          override_test?: boolean
          override_threshold?: boolean
          parsed_date?: string | null
          parsed_duration_seconds?: number | null
          parsed_end_time?: string | null
          parsed_flow_litres_per_hour?: number | null
          parsed_start_time?: string | null
          parsed_water_litres?: number | null
          primary_exclusion_reason?: string | null
          program_name?: string | null
          provider: string
          raw_payload: Json
          raw_row_hash: string
          source_comment?: string | null
          source_row_number: number
          validation_errors?: Json
          validation_status?: string
          validation_warnings?: Json
          vineyard_id: string
          water_flow_reconciliation?: string | null
        }
        Update: {
          additional_reason_codes?: Json
          batch_id?: string
          classification?: string | null
          created_at?: string
          created_session_id?: string | null
          duplicate_reference?: string | null
          duplicate_status?: string
          event_fingerprint?: string | null
          expected_water_litres?: number | null
          external_station_code?: string | null
          external_valve_label?: string | null
          external_valve_name?: string | null
          external_valve_number?: number | null
          id?: string
          is_reversed?: boolean
          matched_mapping_id?: string | null
          matched_valve_id?: string | null
          original_flow_unit?: string | null
          original_flow_value?: number | null
          original_water_unit?: string | null
          original_water_value?: number | null
          override_at?: string | null
          override_by?: string | null
          override_reason?: string | null
          override_test?: boolean
          override_threshold?: boolean
          parsed_date?: string | null
          parsed_duration_seconds?: number | null
          parsed_end_time?: string | null
          parsed_flow_litres_per_hour?: number | null
          parsed_start_time?: string | null
          parsed_water_litres?: number | null
          primary_exclusion_reason?: string | null
          program_name?: string | null
          provider?: string
          raw_payload?: Json
          raw_row_hash?: string
          source_comment?: string | null
          source_row_number?: number
          validation_errors?: Json
          validation_status?: string
          validation_warnings?: Json
          vineyard_id?: string
          water_flow_reconciliation?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "irrigation_import_rows_batch_id_fkey"
            columns: ["batch_id"]
            isOneToOne: false
            referencedRelation: "irrigation_import_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "irrigation_import_rows_created_session_id_fkey"
            columns: ["created_session_id"]
            isOneToOne: false
            referencedRelation: "irrigation_sessions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "irrigation_import_rows_matched_mapping_id_fkey"
            columns: ["matched_mapping_id"]
            isOneToOne: false
            referencedRelation: "irrigation_controller_valve_mappings"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "irrigation_import_rows_matched_valve_id_fkey"
            columns: ["matched_valve_id"]
            isOneToOne: false
            referencedRelation: "irrigation_valves"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "irrigation_import_rows_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      irrigation_rpc_capabilities: {
        Row: {
          capability: string
          function_name: string
          updated_at: string
        }
        Insert: {
          capability: string
          function_name: string
          updated_at?: string
        }
        Update: {
          capability?: string
          function_name?: string
          updated_at?: string
        }
        Relationships: []
      }
      irrigation_session_blocks: {
        Row: {
          allocated_volume_litres: number
          allocation_method: string
          allocation_percentage: number
          block_id: string
          created_at: string
          effective_irrigation_depth_mm: number | null
          effective_volume_litres: number | null
          id: string
          irrigation_depth_mm: number | null
          serviced_area_m2: number | null
          serviced_vine_count: number | null
          session_id: string
          valve_id: string
          variety_id: string | null
          variety_name: string | null
          vineyard_id: string
          water_litres_per_hectare: number | null
          water_litres_per_vine: number | null
        }
        Insert: {
          allocated_volume_litres: number
          allocation_method: string
          allocation_percentage: number
          block_id: string
          created_at?: string
          effective_irrigation_depth_mm?: number | null
          effective_volume_litres?: number | null
          id?: string
          irrigation_depth_mm?: number | null
          serviced_area_m2?: number | null
          serviced_vine_count?: number | null
          session_id: string
          valve_id: string
          variety_id?: string | null
          variety_name?: string | null
          vineyard_id: string
          water_litres_per_hectare?: number | null
          water_litres_per_vine?: number | null
        }
        Update: {
          allocated_volume_litres?: number
          allocation_method?: string
          allocation_percentage?: number
          block_id?: string
          created_at?: string
          effective_irrigation_depth_mm?: number | null
          effective_volume_litres?: number | null
          id?: string
          irrigation_depth_mm?: number | null
          serviced_area_m2?: number | null
          serviced_vine_count?: number | null
          session_id?: string
          valve_id?: string
          variety_id?: string | null
          variety_name?: string | null
          vineyard_id?: string
          water_litres_per_hectare?: number | null
          water_litres_per_vine?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "irrigation_session_blocks_block_id_fkey"
            columns: ["block_id"]
            isOneToOne: false
            referencedRelation: "paddocks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "irrigation_session_blocks_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "irrigation_sessions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "irrigation_session_blocks_valve_id_fkey"
            columns: ["valve_id"]
            isOneToOne: false
            referencedRelation: "irrigation_valves"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "irrigation_session_blocks_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      irrigation_sessions: {
        Row: {
          calculation_method: string
          configuration_snapshot: Json
          created_at: string
          created_by: string | null
          deleted_at: string | null
          duration_minutes: number
          effective_volume_litres: number | null
          external_id: string | null
          external_source_id: string | null
          finished_at: string | null
          flow_litres_per_hour: number | null
          id: string
          import_batch_id: string | null
          integration_api_key_id: string | null
          integration_client_id: string | null
          irrigation_efficiency_percent: number | null
          irrigation_run_id: string | null
          irrigation_system_id: string
          meter_finish_litres: number | null
          meter_start_litres: number | null
          notes: string | null
          origin: string
          original_unit: string | null
          original_value: number | null
          reversed_by_session_id: string | null
          session_date: string
          source_type: string
          started_at: string | null
          status: string
          total_volume_litres: number
          updated_at: string
          updated_by: string | null
          updated_by_integration_client_id: string | null
          valve_id: string
          vineyard_id: string
          vintage_year: number
        }
        Insert: {
          calculation_method: string
          configuration_snapshot: Json
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          duration_minutes: number
          effective_volume_litres?: number | null
          external_id?: string | null
          external_source_id?: string | null
          finished_at?: string | null
          flow_litres_per_hour?: number | null
          id: string
          import_batch_id?: string | null
          integration_api_key_id?: string | null
          integration_client_id?: string | null
          irrigation_efficiency_percent?: number | null
          irrigation_run_id?: string | null
          irrigation_system_id: string
          meter_finish_litres?: number | null
          meter_start_litres?: number | null
          notes?: string | null
          origin?: string
          original_unit?: string | null
          original_value?: number | null
          reversed_by_session_id?: string | null
          session_date: string
          source_type: string
          started_at?: string | null
          status?: string
          total_volume_litres: number
          updated_at?: string
          updated_by?: string | null
          updated_by_integration_client_id?: string | null
          valve_id: string
          vineyard_id: string
          vintage_year: number
        }
        Update: {
          calculation_method?: string
          configuration_snapshot?: Json
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          duration_minutes?: number
          effective_volume_litres?: number | null
          external_id?: string | null
          external_source_id?: string | null
          finished_at?: string | null
          flow_litres_per_hour?: number | null
          id?: string
          import_batch_id?: string | null
          integration_api_key_id?: string | null
          integration_client_id?: string | null
          irrigation_efficiency_percent?: number | null
          irrigation_run_id?: string | null
          irrigation_system_id?: string
          meter_finish_litres?: number | null
          meter_start_litres?: number | null
          notes?: string | null
          origin?: string
          original_unit?: string | null
          original_value?: number | null
          reversed_by_session_id?: string | null
          session_date?: string
          source_type?: string
          started_at?: string | null
          status?: string
          total_volume_litres?: number
          updated_at?: string
          updated_by?: string | null
          updated_by_integration_client_id?: string | null
          valve_id?: string
          vineyard_id?: string
          vintage_year?: number
        }
        Relationships: [
          {
            foreignKeyName: "irrigation_sessions_integration_api_key_id_fkey"
            columns: ["integration_api_key_id"]
            isOneToOne: false
            referencedRelation: "integration_api_keys"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "irrigation_sessions_integration_client_id_fkey"
            columns: ["integration_client_id"]
            isOneToOne: false
            referencedRelation: "integration_clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "irrigation_sessions_irrigation_system_id_fkey"
            columns: ["irrigation_system_id"]
            isOneToOne: false
            referencedRelation: "irrigation_systems"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "irrigation_sessions_updated_by_integration_client_id_fkey"
            columns: ["updated_by_integration_client_id"]
            isOneToOne: false
            referencedRelation: "integration_clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "irrigation_sessions_valve_id_fkey"
            columns: ["valve_id"]
            isOneToOne: false
            referencedRelation: "irrigation_valves"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "irrigation_sessions_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      irrigation_systems: {
        Row: {
          controller_name: string | null
          controller_provider: string | null
          created_at: string
          created_by: string | null
          default_unit_system: string | null
          external_controller_id: string | null
          id: string
          is_active: boolean
          name: string
          notes: string | null
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          water_source: string | null
        }
        Insert: {
          controller_name?: string | null
          controller_provider?: string | null
          created_at?: string
          created_by?: string | null
          default_unit_system?: string | null
          external_controller_id?: string | null
          id?: string
          is_active?: boolean
          name: string
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
          water_source?: string | null
        }
        Update: {
          controller_name?: string | null
          controller_provider?: string | null
          created_at?: string
          created_by?: string | null
          default_unit_system?: string | null
          external_controller_id?: string | null
          id?: string
          is_active?: boolean
          name?: string
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
          water_source?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "irrigation_systems_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      irrigation_valve_blocks: {
        Row: {
          allocation_method: string
          allocation_percentage: number | null
          block_id: string
          configured_flow_litres_per_hour: number | null
          created_at: string
          created_by: string | null
          effective_from: string | null
          effective_to: string | null
          id: string
          is_active: boolean
          row_end: number | null
          row_start: number | null
          serviced_area_m2: number | null
          serviced_emitter_count: number | null
          serviced_vine_count: number | null
          updated_at: string
          updated_by: string | null
          valve_id: string
          vineyard_id: string
        }
        Insert: {
          allocation_method?: string
          allocation_percentage?: number | null
          block_id: string
          configured_flow_litres_per_hour?: number | null
          created_at?: string
          created_by?: string | null
          effective_from?: string | null
          effective_to?: string | null
          id?: string
          is_active?: boolean
          row_end?: number | null
          row_start?: number | null
          serviced_area_m2?: number | null
          serviced_emitter_count?: number | null
          serviced_vine_count?: number | null
          updated_at?: string
          updated_by?: string | null
          valve_id: string
          vineyard_id: string
        }
        Update: {
          allocation_method?: string
          allocation_percentage?: number | null
          block_id?: string
          configured_flow_litres_per_hour?: number | null
          created_at?: string
          created_by?: string | null
          effective_from?: string | null
          effective_to?: string | null
          id?: string
          is_active?: boolean
          row_end?: number | null
          row_start?: number | null
          serviced_area_m2?: number | null
          serviced_emitter_count?: number | null
          serviced_vine_count?: number | null
          updated_at?: string
          updated_by?: string | null
          valve_id?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "irrigation_valve_blocks_block_id_fkey"
            columns: ["block_id"]
            isOneToOne: false
            referencedRelation: "paddocks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "irrigation_valve_blocks_valve_id_fkey"
            columns: ["valve_id"]
            isOneToOne: false
            referencedRelation: "irrigation_valves"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "irrigation_valve_blocks_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      irrigation_valve_rows: {
        Row: {
          block_id: string
          created_at: string
          created_by: string | null
          emitter_count: number | null
          emitter_count_basis: string | null
          emitter_count_is_estimated: boolean | null
          id: string
          is_active: boolean
          row_id: string | null
          row_label: string | null
          row_length_metres: number | null
          row_number: number
          row_weight: number | null
          updated_at: string
          updated_by: string | null
          valve_id: string
          vine_count: number | null
          vine_count_basis: string | null
          vine_count_is_estimated: boolean | null
          vineyard_id: string
          weighting_basis: string | null
        }
        Insert: {
          block_id: string
          created_at?: string
          created_by?: string | null
          emitter_count?: number | null
          emitter_count_basis?: string | null
          emitter_count_is_estimated?: boolean | null
          id?: string
          is_active?: boolean
          row_id?: string | null
          row_label?: string | null
          row_length_metres?: number | null
          row_number: number
          row_weight?: number | null
          updated_at?: string
          updated_by?: string | null
          valve_id: string
          vine_count?: number | null
          vine_count_basis?: string | null
          vine_count_is_estimated?: boolean | null
          vineyard_id: string
          weighting_basis?: string | null
        }
        Update: {
          block_id?: string
          created_at?: string
          created_by?: string | null
          emitter_count?: number | null
          emitter_count_basis?: string | null
          emitter_count_is_estimated?: boolean | null
          id?: string
          is_active?: boolean
          row_id?: string | null
          row_label?: string | null
          row_length_metres?: number | null
          row_number?: number
          row_weight?: number | null
          updated_at?: string
          updated_by?: string | null
          valve_id?: string
          vine_count?: number | null
          vine_count_basis?: string | null
          vine_count_is_estimated?: boolean | null
          vineyard_id?: string
          weighting_basis?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "irrigation_valve_rows_block_id_fkey"
            columns: ["block_id"]
            isOneToOne: false
            referencedRelation: "paddocks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "irrigation_valve_rows_valve_id_fkey"
            columns: ["valve_id"]
            isOneToOne: false
            referencedRelation: "irrigation_valves"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "irrigation_valve_rows_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      irrigation_valves: {
        Row: {
          configured_flow_litres_per_hour: number | null
          created_at: string
          created_by: string | null
          external_station_id: string | null
          id: string
          irrigation_system_id: string
          is_active: boolean
          measured_flow_litres_per_hour: number | null
          name: string
          notes: string | null
          updated_at: string
          updated_by: string | null
          valve_number: string | null
          vineyard_id: string
        }
        Insert: {
          configured_flow_litres_per_hour?: number | null
          created_at?: string
          created_by?: string | null
          external_station_id?: string | null
          id?: string
          irrigation_system_id: string
          is_active?: boolean
          measured_flow_litres_per_hour?: number | null
          name: string
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
          valve_number?: string | null
          vineyard_id: string
        }
        Update: {
          configured_flow_litres_per_hour?: number | null
          created_at?: string
          created_by?: string | null
          external_station_id?: string | null
          id?: string
          irrigation_system_id?: string
          is_active?: boolean
          measured_flow_litres_per_hour?: number | null
          name?: string
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
          valve_number?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "irrigation_valves_irrigation_system_id_fkey"
            columns: ["irrigation_system_id"]
            isOneToOne: false
            referencedRelation: "irrigation_systems"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "irrigation_valves_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      maintenance_logs: {
        Row: {
          archived_at: string | null
          archived_by: string | null
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          date: string
          deleted_at: string | null
          equipment_ref_id: string | null
          equipment_source: string | null
          finalized_at: string | null
          finalized_by: string | null
          hours: number
          id: string
          is_archived: boolean
          is_finalized: boolean
          item_name: string
          labour_cost: number
          machine_hours: number | null
          parts_cost: number
          parts_used: string
          photo_path: string | null
          sync_version: number
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          work_completed: string
        }
        Insert: {
          archived_at?: string | null
          archived_by?: string | null
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          date?: string
          deleted_at?: string | null
          equipment_ref_id?: string | null
          equipment_source?: string | null
          finalized_at?: string | null
          finalized_by?: string | null
          hours?: number
          id?: string
          is_archived?: boolean
          is_finalized?: boolean
          item_name?: string
          labour_cost?: number
          machine_hours?: number | null
          parts_cost?: number
          parts_used?: string
          photo_path?: string | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
          work_completed?: string
        }
        Update: {
          archived_at?: string | null
          archived_by?: string | null
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          date?: string
          deleted_at?: string | null
          equipment_ref_id?: string | null
          equipment_source?: string | null
          finalized_at?: string | null
          finalized_by?: string | null
          hours?: number
          id?: string
          is_archived?: boolean
          is_finalized?: boolean
          item_name?: string
          labour_cost?: number
          machine_hours?: number | null
          parts_cost?: number
          parts_used?: string
          photo_path?: string | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
          work_completed?: string
        }
        Relationships: [
          {
            foreignKeyName: "maintenance_logs_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      mait_intelliweb_channel_mappings: {
        Row: {
          canonical_metric: string
          channel_key: string
          channel_number: number | null
          conversion_multiplier: number
          conversion_offset: number
          created_at: string
          created_by: string | null
          id: string
          is_active: boolean
          module_id: string
          semantics: string | null
          source_label: string | null
          source_unit: string | null
          updated_at: string
          updated_by: string | null
          vineyard_id: string
        }
        Insert: {
          canonical_metric: string
          channel_key: string
          channel_number?: number | null
          conversion_multiplier?: number
          conversion_offset?: number
          created_at?: string
          created_by?: string | null
          id?: string
          is_active?: boolean
          module_id: string
          semantics?: string | null
          source_label?: string | null
          source_unit?: string | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
        }
        Update: {
          canonical_metric?: string
          channel_key?: string
          channel_number?: number | null
          conversion_multiplier?: number
          conversion_offset?: number
          created_at?: string
          created_by?: string | null
          id?: string
          is_active?: boolean
          module_id?: string
          semantics?: string | null
          source_label?: string | null
          source_unit?: string | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "mait_intelliweb_channel_mappings_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      mait_intelliweb_connections: {
        Row: {
          created_at: string
          created_by: string | null
          id: string
          is_active: boolean
          last_test_status: string | null
          last_tested_at: string | null
          network_id: string
          network_name: string | null
          password_secret_id: string
          rainfall_publish_enabled: boolean
          timezone: string | null
          updated_at: string
          updated_by: string | null
          username: string
          vineyard_id: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          id?: string
          is_active?: boolean
          last_test_status?: string | null
          last_tested_at?: string | null
          network_id: string
          network_name?: string | null
          password_secret_id: string
          rainfall_publish_enabled?: boolean
          timezone?: string | null
          updated_at?: string
          updated_by?: string | null
          username: string
          vineyard_id: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          id?: string
          is_active?: boolean
          last_test_status?: string | null
          last_tested_at?: string | null
          network_id?: string
          network_name?: string | null
          password_secret_id?: string
          rainfall_publish_enabled?: boolean
          timezone?: string | null
          updated_at?: string
          updated_by?: string | null
          username?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "mait_intelliweb_connections_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: true
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      mait_intelliweb_modules: {
        Row: {
          created_at: string
          created_by: string | null
          id: string
          irrigation_system_id: string | null
          is_active: boolean
          metadata: Json
          module_id: string
          module_name: string | null
          module_role: string
          updated_at: string
          updated_by: string | null
          vineyard_id: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          id?: string
          irrigation_system_id?: string | null
          is_active?: boolean
          metadata?: Json
          module_id: string
          module_name?: string | null
          module_role: string
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          id?: string
          irrigation_system_id?: string | null
          is_active?: boolean
          metadata?: Json
          module_id?: string
          module_name?: string | null
          module_role?: string
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "mait_intelliweb_modules_irrigation_system_id_fkey"
            columns: ["irrigation_system_id"]
            isOneToOne: false
            referencedRelation: "irrigation_systems"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "mait_intelliweb_modules_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      mait_intelliweb_sync_state: {
        Row: {
          auto_commit_enabled: boolean
          auto_sync_enabled: boolean
          id: string
          incomplete_range: boolean
          last_error_code: string | null
          last_error_message: string | null
          last_source_event_at: string | null
          last_successful_sync_at: string | null
          last_sync_attempt_at: string | null
          module_id: string
          overlap_days: number
          records_created: number
          records_existing: number
          records_needing_mapping: number
          records_needing_review: number
          records_received: number
          sync_kind: string
          updated_at: string
          vineyard_id: string
        }
        Insert: {
          auto_commit_enabled?: boolean
          auto_sync_enabled?: boolean
          id?: string
          incomplete_range?: boolean
          last_error_code?: string | null
          last_error_message?: string | null
          last_source_event_at?: string | null
          last_successful_sync_at?: string | null
          last_sync_attempt_at?: string | null
          module_id: string
          overlap_days?: number
          records_created?: number
          records_existing?: number
          records_needing_mapping?: number
          records_needing_review?: number
          records_received?: number
          sync_kind: string
          updated_at?: string
          vineyard_id: string
        }
        Update: {
          auto_commit_enabled?: boolean
          auto_sync_enabled?: boolean
          id?: string
          incomplete_range?: boolean
          last_error_code?: string | null
          last_error_message?: string | null
          last_source_event_at?: string | null
          last_successful_sync_at?: string | null
          last_sync_attempt_at?: string | null
          module_id?: string
          overlap_days?: number
          records_created?: number
          records_existing?: number
          records_needing_mapping?: number
          records_needing_review?: number
          records_received?: number
          sync_kind?: string
          updated_at?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "mait_intelliweb_sync_state_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      mait_intelliweb_usage_events: {
        Row: {
          channel_name: string | null
          channel_number: number
          created_by: string | null
          created_session_id: string | null
          duration_minutes: number | null
          duration_source: string | null
          event_fingerprint: string
          event_identity_key: string
          event_local_date: string
          event_started_at: string
          first_seen_at: string
          id: string
          last_seen_at: string
          mapping_id: string | null
          module_id: string
          module_name: string | null
          network_id: string
          original_volume: number | null
          original_volume_unit: string | null
          raw_payload: Json | null
          reported_volume_litres: number | null
          review_reason: string | null
          status: string
          updated_at: string
          vineyard_id: string
          volume_source: string | null
        }
        Insert: {
          channel_name?: string | null
          channel_number: number
          created_by?: string | null
          created_session_id?: string | null
          duration_minutes?: number | null
          duration_source?: string | null
          event_fingerprint: string
          event_identity_key: string
          event_local_date: string
          event_started_at: string
          first_seen_at?: string
          id?: string
          last_seen_at?: string
          mapping_id?: string | null
          module_id: string
          module_name?: string | null
          network_id: string
          original_volume?: number | null
          original_volume_unit?: string | null
          raw_payload?: Json | null
          reported_volume_litres?: number | null
          review_reason?: string | null
          status?: string
          updated_at?: string
          vineyard_id: string
          volume_source?: string | null
        }
        Update: {
          channel_name?: string | null
          channel_number?: number
          created_by?: string | null
          created_session_id?: string | null
          duration_minutes?: number | null
          duration_source?: string | null
          event_fingerprint?: string
          event_identity_key?: string
          event_local_date?: string
          event_started_at?: string
          first_seen_at?: string
          id?: string
          last_seen_at?: string
          mapping_id?: string | null
          module_id?: string
          module_name?: string | null
          network_id?: string
          original_volume?: number | null
          original_volume_unit?: string | null
          raw_payload?: Json | null
          reported_volume_litres?: number | null
          review_reason?: string | null
          status?: string
          updated_at?: string
          vineyard_id?: string
          volume_source?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "mait_intelliweb_usage_events_created_session_id_fkey"
            columns: ["created_session_id"]
            isOneToOne: false
            referencedRelation: "irrigation_sessions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "mait_intelliweb_usage_events_mapping_id_fkey"
            columns: ["mapping_id"]
            isOneToOne: false
            referencedRelation: "irrigation_controller_valve_mappings"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "mait_intelliweb_usage_events_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      manual_spray_operations: {
        Row: {
          actor_user_id: string
          completed_at: string
          manual_entry_id: string
          operation_id: string
          operation_kind: string
          request_fingerprint: string
          result: Json
          vineyard_id: string
        }
        Insert: {
          actor_user_id: string
          completed_at?: string
          manual_entry_id: string
          operation_id: string
          operation_kind: string
          request_fingerprint: string
          result: Json
          vineyard_id: string
        }
        Update: {
          actor_user_id?: string
          completed_at?: string
          manual_entry_id?: string
          operation_id?: string
          operation_kind?: string
          request_fingerprint?: string
          result?: Json
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "manual_spray_operations_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      manual_spray_tombstones: {
        Row: {
          deleted_at: string
          deleted_by: string
          manual_entry_id: string
          spray_record_id: string
          trip_id: string
          vineyard_id: string
        }
        Insert: {
          deleted_at?: string
          deleted_by: string
          manual_entry_id: string
          spray_record_id: string
          trip_id: string
          vineyard_id: string
        }
        Update: {
          deleted_at?: string
          deleted_by?: string
          manual_entry_id?: string
          spray_record_id?: string
          trip_id?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "manual_spray_tombstones_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      master_chemical_review_actions: {
        Row: {
          action: string
          base_revision: number
          conflict: Json | null
          field: string | null
          id: string
          master_chemical_id: string
          patch: Json | null
          performed_at: string
          performed_by: string
          preview_id: string | null
          reason: string
          result_revision: number | null
          selected: string | null
        }
        Insert: {
          action: string
          base_revision: number
          conflict?: Json | null
          field?: string | null
          id?: string
          master_chemical_id: string
          patch?: Json | null
          performed_at?: string
          performed_by: string
          preview_id?: string | null
          reason: string
          result_revision?: number | null
          selected?: string | null
        }
        Update: {
          action?: string
          base_revision?: number
          conflict?: Json | null
          field?: string | null
          id?: string
          master_chemical_id?: string
          patch?: Json | null
          performed_at?: string
          performed_by?: string
          preview_id?: string | null
          reason?: string
          result_revision?: number | null
          selected?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "master_chemical_review_actions_master_chemical_id_fkey"
            columns: ["master_chemical_id"]
            isOneToOne: false
            referencedRelation: "master_chemicals"
            referencedColumns: ["id"]
          },
        ]
      }
      master_chemical_versions: {
        Row: {
          catalogue_version: number
          change_reason: string | null
          changed_at: string
          changed_by: string | null
          id: string
          master_chemical_id: string
          snapshot: Json
        }
        Insert: {
          catalogue_version: number
          change_reason?: string | null
          changed_at?: string
          changed_by?: string | null
          id?: string
          master_chemical_id: string
          snapshot: Json
        }
        Update: {
          catalogue_version?: number
          change_reason?: string | null
          changed_at?: string
          changed_by?: string | null
          id?: string
          master_chemical_id?: string
          snapshot?: Json
        }
        Relationships: [
          {
            foreignKeyName: "master_chemical_versions_master_chemical_id_fkey"
            columns: ["master_chemical_id"]
            isOneToOne: false
            referencedRelation: "master_chemicals"
            referencedColumns: ["id"]
          },
        ]
      }
      master_chemicals: {
        Row: {
          active_ingredients: Json
          activity_group_scheme: string | null
          activity_group_table_version: number | null
          activity_groups: string[]
          catalogue_version: number
          common_names: string[]
          created_at: string
          form_type: string | null
          id: string
          intelligence_schema_version: number
          label_rate_bases: string[]
          label_reference: string | null
          label_version: string | null
          product_category: string | null
          registered_product_name: string
          registered_uses: Json
          registrant: string | null
          registration_country: string
          registration_identity_key: string | null
          registration_number: string
          registration_scheme: string
          resistance_classification_state: string
          retrieved_at: string | null
          review_notes: string | null
          review_status: string
          reviewed_at: string | null
          reviewed_by: string | null
          source_kind: string
          source_reference: string | null
          updated_at: string
          verification_conflicts: Json | null
          verification_sources: Json | null
          verification_status: string
          verification_unresolved_fields: string[] | null
          verified_at: string | null
          viticulture_rates: Json
        }
        Insert: {
          active_ingredients?: Json
          activity_group_scheme?: string | null
          activity_group_table_version?: number | null
          activity_groups?: string[]
          catalogue_version?: number
          common_names?: string[]
          created_at?: string
          form_type?: string | null
          id?: string
          intelligence_schema_version?: number
          label_rate_bases?: string[]
          label_reference?: string | null
          label_version?: string | null
          product_category?: string | null
          registered_product_name: string
          registered_uses?: Json
          registrant?: string | null
          registration_country: string
          registration_identity_key?: string | null
          registration_number: string
          registration_scheme: string
          resistance_classification_state?: string
          retrieved_at?: string | null
          review_notes?: string | null
          review_status?: string
          reviewed_at?: string | null
          reviewed_by?: string | null
          source_kind?: string
          source_reference?: string | null
          updated_at?: string
          verification_conflicts?: Json | null
          verification_sources?: Json | null
          verification_status?: string
          verification_unresolved_fields?: string[] | null
          verified_at?: string | null
          viticulture_rates?: Json
        }
        Update: {
          active_ingredients?: Json
          activity_group_scheme?: string | null
          activity_group_table_version?: number | null
          activity_groups?: string[]
          catalogue_version?: number
          common_names?: string[]
          created_at?: string
          form_type?: string | null
          id?: string
          intelligence_schema_version?: number
          label_rate_bases?: string[]
          label_reference?: string | null
          label_version?: string | null
          product_category?: string | null
          registered_product_name?: string
          registered_uses?: Json
          registrant?: string | null
          registration_country?: string
          registration_identity_key?: string | null
          registration_number?: string
          registration_scheme?: string
          resistance_classification_state?: string
          retrieved_at?: string | null
          review_notes?: string | null
          review_status?: string
          reviewed_at?: string | null
          reviewed_by?: string | null
          source_kind?: string
          source_reference?: string | null
          updated_at?: string
          verification_conflicts?: Json | null
          verification_sources?: Json | null
          verification_status?: string
          verification_unresolved_fields?: string[] | null
          verified_at?: string | null
          viticulture_rates?: Json
        }
        Relationships: []
      }
      master_review_previews: {
        Row: {
          base_revision: number
          changes: Json | null
          consumed_action_id: string | null
          consumed_at: string | null
          created_at: string
          expires_at: string
          id: string
          master_chemical_id: string
          outcome: string
          proposed_patch: Json
          requested_by: string
        }
        Insert: {
          base_revision: number
          changes?: Json | null
          consumed_action_id?: string | null
          consumed_at?: string | null
          created_at?: string
          expires_at?: string
          id?: string
          master_chemical_id: string
          outcome: string
          proposed_patch: Json
          requested_by: string
        }
        Update: {
          base_revision?: number
          changes?: Json | null
          consumed_action_id?: string | null
          consumed_at?: string | null
          created_at?: string
          expires_at?: string
          id?: string
          master_chemical_id?: string
          outcome?: string
          proposed_patch?: Json
          requested_by?: string
        }
        Relationships: [
          {
            foreignKeyName: "master_review_previews_master_chemical_id_fkey"
            columns: ["master_chemical_id"]
            isOneToOne: false
            referencedRelation: "master_chemicals"
            referencedColumns: ["id"]
          },
        ]
      }
      material_catalogue: {
        Row: {
          category: string
          created_at: string
          default_unit: string
          id: string
          is_active: boolean
          key: string
          name: string
          sort_order: number
          updated_at: string
        }
        Insert: {
          category: string
          created_at?: string
          default_unit: string
          id?: string
          is_active?: boolean
          key: string
          name: string
          sort_order?: number
          updated_at?: string
        }
        Update: {
          category?: string
          created_at?: string
          default_unit?: string
          id?: string
          is_active?: boolean
          key?: string
          name?: string
          sort_order?: number
          updated_at?: string
        }
        Relationships: []
      }
      operational_tool_catalogue: {
        Row: {
          added_in: string | null
          created_at: string
          display_order: number
          is_active: boolean
          tool_id: string
        }
        Insert: {
          added_in?: string | null
          created_at?: string
          display_order: number
          is_active?: boolean
          tool_id: string
        }
        Update: {
          added_in?: string | null
          created_at?: string
          display_order?: number
          is_active?: boolean
          tool_id?: string
        }
        Relationships: []
      }
      paddock_row_identity_repair_audit: {
        Row: {
          block_id: string
          id: string
          new_end_point_id: string | null
          new_row_id: string
          new_start_point_id: string | null
          old_row_id: string
          repair_reason: string
          repaired_at: string
          row_number: number | null
          vineyard_id: string
        }
        Insert: {
          block_id: string
          id?: string
          new_end_point_id?: string | null
          new_row_id: string
          new_start_point_id?: string | null
          old_row_id: string
          repair_reason: string
          repaired_at?: string
          row_number?: number | null
          vineyard_id: string
        }
        Update: {
          block_id?: string
          id?: string
          new_end_point_id?: string | null
          new_row_id?: string
          new_start_point_id?: string | null
          old_row_id?: string
          repair_reason?: string
          repaired_at?: string
          row_number?: number | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "paddock_row_identity_repair_audit_block_id_fkey"
            columns: ["block_id"]
            isOneToOne: false
            referencedRelation: "paddocks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "paddock_row_identity_repair_audit_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      paddock_soil_profiles: {
        Row: {
          australian_soil_classification: string | null
          australian_soil_classification_code: string | null
          available_water_capacity_mm_per_m: number | null
          confidence: string | null
          country_code: string | null
          created_at: string
          drainage_risk: string | null
          effective_root_depth_m: number | null
          id: string
          infiltration_risk: string | null
          irrigation_soil_class: string | null
          is_manual_override: boolean
          land_soil_capability: string | null
          land_soil_capability_class: number | null
          lookup_latitude: number | null
          lookup_longitude: number | null
          management_allowed_depletion_percent: number | null
          manual_notes: string | null
          model_version: string
          paddock_id: string | null
          raw_source_json: Json | null
          region_code: string | null
          soil_description: string | null
          soil_landscape: string | null
          soil_landscape_code: string | null
          soil_texture_class: string | null
          source: string
          source_dataset: string | null
          source_feature_id: string | null
          source_name: string | null
          source_provider: string | null
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          waterlogging_risk: string | null
        }
        Insert: {
          australian_soil_classification?: string | null
          australian_soil_classification_code?: string | null
          available_water_capacity_mm_per_m?: number | null
          confidence?: string | null
          country_code?: string | null
          created_at?: string
          drainage_risk?: string | null
          effective_root_depth_m?: number | null
          id?: string
          infiltration_risk?: string | null
          irrigation_soil_class?: string | null
          is_manual_override?: boolean
          land_soil_capability?: string | null
          land_soil_capability_class?: number | null
          lookup_latitude?: number | null
          lookup_longitude?: number | null
          management_allowed_depletion_percent?: number | null
          manual_notes?: string | null
          model_version?: string
          paddock_id?: string | null
          raw_source_json?: Json | null
          region_code?: string | null
          soil_description?: string | null
          soil_landscape?: string | null
          soil_landscape_code?: string | null
          soil_texture_class?: string | null
          source?: string
          source_dataset?: string | null
          source_feature_id?: string | null
          source_name?: string | null
          source_provider?: string | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
          waterlogging_risk?: string | null
        }
        Update: {
          australian_soil_classification?: string | null
          australian_soil_classification_code?: string | null
          available_water_capacity_mm_per_m?: number | null
          confidence?: string | null
          country_code?: string | null
          created_at?: string
          drainage_risk?: string | null
          effective_root_depth_m?: number | null
          id?: string
          infiltration_risk?: string | null
          irrigation_soil_class?: string | null
          is_manual_override?: boolean
          land_soil_capability?: string | null
          land_soil_capability_class?: number | null
          lookup_latitude?: number | null
          lookup_longitude?: number | null
          management_allowed_depletion_percent?: number | null
          manual_notes?: string | null
          model_version?: string
          paddock_id?: string | null
          raw_source_json?: Json | null
          region_code?: string | null
          soil_description?: string | null
          soil_landscape?: string | null
          soil_landscape_code?: string | null
          soil_texture_class?: string | null
          source?: string
          source_dataset?: string | null
          source_feature_id?: string | null
          source_name?: string | null
          source_provider?: string | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
          waterlogging_risk?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "paddock_soil_profiles_irrigation_soil_class_fkey"
            columns: ["irrigation_soil_class"]
            isOneToOne: false
            referencedRelation: "soil_class_defaults"
            referencedColumns: ["irrigation_soil_class"]
          },
          {
            foreignKeyName: "paddock_soil_profiles_paddock_id_fkey"
            columns: ["paddock_id"]
            isOneToOne: true
            referencedRelation: "paddocks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "paddock_soil_profiles_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      paddocks: {
        Row: {
          budburst_date: string | null
          calculation_mode_override: string | null
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          emitter_spacing: number | null
          flow_per_emitter: number | null
          flowering_date: string | null
          harvest_date: string | null
          id: string
          intermediate_post_spacing: number | null
          irrigation_efficiency_percent: number | null
          name: string
          planting_year: number | null
          polygon_points: Json | null
          reset_mode_override: string | null
          row_direction: number | null
          row_length_override: number | null
          row_length_overrides: Json | null
          row_offset: number | null
          row_width: number | null
          rows: Json | null
          sync_version: number
          updated_at: string
          updated_by: string | null
          variety_allocations: Json | null
          veraison_date: string | null
          vine_count_override: number | null
          vine_spacing: number | null
          vineyard_id: string
        }
        Insert: {
          budburst_date?: string | null
          calculation_mode_override?: string | null
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          emitter_spacing?: number | null
          flow_per_emitter?: number | null
          flowering_date?: string | null
          harvest_date?: string | null
          id?: string
          intermediate_post_spacing?: number | null
          irrigation_efficiency_percent?: number | null
          name: string
          planting_year?: number | null
          polygon_points?: Json | null
          reset_mode_override?: string | null
          row_direction?: number | null
          row_length_override?: number | null
          row_length_overrides?: Json | null
          row_offset?: number | null
          row_width?: number | null
          rows?: Json | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          variety_allocations?: Json | null
          veraison_date?: string | null
          vine_count_override?: number | null
          vine_spacing?: number | null
          vineyard_id: string
        }
        Update: {
          budburst_date?: string | null
          calculation_mode_override?: string | null
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          emitter_spacing?: number | null
          flow_per_emitter?: number | null
          flowering_date?: string | null
          harvest_date?: string | null
          id?: string
          intermediate_post_spacing?: number | null
          irrigation_efficiency_percent?: number | null
          name?: string
          planting_year?: number | null
          polygon_points?: Json | null
          reset_mode_override?: string | null
          row_direction?: number | null
          row_length_override?: number | null
          row_length_overrides?: Json | null
          row_offset?: number | null
          row_width?: number | null
          rows?: Json | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          variety_allocations?: Json | null
          veraison_date?: string | null
          vine_count_override?: number | null
          vine_spacing?: number | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "paddocks_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      picking_record_financials: {
        Row: {
          picking_record_id: string
          price_per_tonne: number | null
          sold_to: string | null
          updated_at: string
          updated_by: string | null
          vineyard_id: string
        }
        Insert: {
          picking_record_id: string
          price_per_tonne?: number | null
          sold_to?: string | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
        }
        Update: {
          picking_record_id?: string
          price_per_tonne?: number | null
          sold_to?: string | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "picking_record_financials_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      picking_records: {
        Row: {
          client_updated_at: string | null
          clone: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          grape_value: number | null
          id: string
          notes: string
          paddock_id: string
          paddock_name: string
          ph: number | null
          picked_at: string
          planting_group_key: string | null
          price_per_tonne: number | null
          purpose: string
          rootstock: string | null
          sold: boolean
          sold_to: string | null
          sugar_unit: string | null
          sugar_value: number | null
          sync_version: number
          ta_g_l: number | null
          updated_at: string
          updated_by: string | null
          variety_allocation_ids: string[] | null
          variety_id: string | null
          variety_key: string | null
          variety_name: string
          vineyard_id: string
          vintage: number
          weight_kg: number
        }
        Insert: {
          client_updated_at?: string | null
          clone?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          grape_value?: number | null
          id?: string
          notes?: string
          paddock_id: string
          paddock_name?: string
          ph?: number | null
          picked_at: string
          planting_group_key?: string | null
          price_per_tonne?: number | null
          purpose?: string
          rootstock?: string | null
          sold?: boolean
          sold_to?: string | null
          sugar_unit?: string | null
          sugar_value?: number | null
          sync_version?: number
          ta_g_l?: number | null
          updated_at?: string
          updated_by?: string | null
          variety_allocation_ids?: string[] | null
          variety_id?: string | null
          variety_key?: string | null
          variety_name?: string
          vineyard_id: string
          vintage?: number
          weight_kg: number
        }
        Update: {
          client_updated_at?: string | null
          clone?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          grape_value?: number | null
          id?: string
          notes?: string
          paddock_id?: string
          paddock_name?: string
          ph?: number | null
          picked_at?: string
          planting_group_key?: string | null
          price_per_tonne?: number | null
          purpose?: string
          rootstock?: string | null
          sold?: boolean
          sold_to?: string | null
          sugar_unit?: string | null
          sugar_value?: number | null
          sync_version?: number
          ta_g_l?: number | null
          updated_at?: string
          updated_by?: string | null
          variety_allocation_ids?: string[] | null
          variety_id?: string | null
          variety_key?: string | null
          variety_name?: string
          vineyard_id?: string
          vintage?: number
          weight_kg?: number
        }
        Relationships: [
          {
            foreignKeyName: "picking_records_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      pin_block_link_repair_audit: {
        Row: {
          after_row: Json
          applied_at: string
          before_row: Json
          pin_id: string
          repair_basis: string
          rollback_after_row: Json | null
          rolled_back_at: string | null
          run_id: string
          status: string
          target_paddock_id: string
          vineyard_id: string
        }
        Insert: {
          after_row: Json
          applied_at?: string
          before_row: Json
          pin_id: string
          repair_basis: string
          rollback_after_row?: Json | null
          rolled_back_at?: string | null
          run_id: string
          status: string
          target_paddock_id: string
          vineyard_id: string
        }
        Update: {
          after_row?: Json
          applied_at?: string
          before_row?: Json
          pin_id?: string
          repair_basis?: string
          rollback_after_row?: Json | null
          rolled_back_at?: string | null
          run_id?: string
          status?: string
          target_paddock_id?: string
          vineyard_id?: string
        }
        Relationships: []
      }
      pin_capture_evidence: {
        Row: {
          aisle_lock: Json | null
          capture_button_name: string
          capture_mode: string
          capture_provenance: Json
          capture_user_id: string | null
          captured_at: string
          created_by: string
          evidence_revision: number
          geometry_hash: string | null
          geometry_revision: string | null
          heading_degrees: number | null
          heading_observed_at: string | null
          heading_source: string | null
          horizontal_accuracy_m: number | null
          location_observed_at: string
          observations: Json
          payload_hash: string | null
          pin_id: string
          pressed_side: string | null
          raw_latitude: number
          raw_longitude: number
          received_at: string
          resolver_version: string
          supported_along_row_distance_m: number | null
          supported_driving_row: number | null
          supported_paddock_id: string | null
          supported_pin_row: number | null
          supported_pin_side: string | null
          supported_snapped_latitude: number | null
          supported_snapped_longitude: number | null
          trip_id: string | null
          vineyard_id: string
        }
        Insert: {
          aisle_lock?: Json | null
          capture_button_name?: string
          capture_mode?: string
          capture_provenance?: Json
          capture_user_id?: string | null
          captured_at: string
          created_by?: string
          evidence_revision: number
          geometry_hash?: string | null
          geometry_revision?: string | null
          heading_degrees?: number | null
          heading_observed_at?: string | null
          heading_source?: string | null
          horizontal_accuracy_m?: number | null
          location_observed_at: string
          observations?: Json
          payload_hash?: string | null
          pin_id: string
          pressed_side?: string | null
          raw_latitude: number
          raw_longitude: number
          received_at?: string
          resolver_version?: string
          supported_along_row_distance_m?: number | null
          supported_driving_row?: number | null
          supported_paddock_id?: string | null
          supported_pin_row?: number | null
          supported_pin_side?: string | null
          supported_snapped_latitude?: number | null
          supported_snapped_longitude?: number | null
          trip_id?: string | null
          vineyard_id: string
        }
        Update: {
          aisle_lock?: Json | null
          capture_button_name?: string
          capture_mode?: string
          capture_provenance?: Json
          capture_user_id?: string | null
          captured_at?: string
          created_by?: string
          evidence_revision?: number
          geometry_hash?: string | null
          geometry_revision?: string | null
          heading_degrees?: number | null
          heading_observed_at?: string | null
          heading_source?: string | null
          horizontal_accuracy_m?: number | null
          location_observed_at?: string
          observations?: Json
          payload_hash?: string | null
          pin_id?: string
          pressed_side?: string | null
          raw_latitude?: number
          raw_longitude?: number
          received_at?: string
          resolver_version?: string
          supported_along_row_distance_m?: number | null
          supported_driving_row?: number | null
          supported_paddock_id?: string | null
          supported_pin_row?: number | null
          supported_pin_side?: string | null
          supported_snapped_latitude?: number | null
          supported_snapped_longitude?: number | null
          trip_id?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "pin_capture_evidence_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      pin_location_confirmation_operations: {
        Row: {
          created_at: string
          evidence_revision: number
          operation_id: string
          outcome: string
          payload_hash: string
          pin_id: string
        }
        Insert: {
          created_at?: string
          evidence_revision: number
          operation_id: string
          outcome: string
          payload_hash: string
          pin_id: string
        }
        Update: {
          created_at?: string
          evidence_revision?: number
          operation_id?: string
          outcome?: string
          payload_hash?: string
          pin_id?: string
        }
        Relationships: []
      }
      pin_location_enrichment_audit: {
        Row: {
          after_placement: Json
          before_placement: Json
          created_at: string
          detail: Json
          evidence_revision: number
          id: string
          lease_token: string | null
          outcome: string
          pin_id: string
          resolver_version: string
        }
        Insert: {
          after_placement?: Json
          before_placement?: Json
          created_at?: string
          detail?: Json
          evidence_revision: number
          id?: string
          lease_token?: string | null
          outcome: string
          pin_id: string
          resolver_version: string
        }
        Update: {
          after_placement?: Json
          before_placement?: Json
          created_at?: string
          detail?: Json
          evidence_revision?: number
          id?: string
          lease_token?: string | null
          outcome?: string
          pin_id?: string
          resolver_version?: string
        }
        Relationships: []
      }
      pin_location_enrichment_queue: {
        Row: {
          attempts: number
          available_at: string
          evidence_revision: number
          last_error: string | null
          lease_expires_at: string | null
          lease_token: string | null
          pin_id: string
          resolver_version: string
          terminal_at: string | null
        }
        Insert: {
          attempts?: number
          available_at?: string
          evidence_revision: number
          last_error?: string | null
          lease_expires_at?: string | null
          lease_token?: string | null
          pin_id: string
          resolver_version: string
          terminal_at?: string | null
        }
        Update: {
          attempts?: number
          available_at?: string
          evidence_revision?: number
          last_error?: string | null
          lease_expires_at?: string | null
          lease_token?: string | null
          pin_id?: string
          resolver_version?: string
          terminal_at?: string | null
        }
        Relationships: []
      }
      pin_location_geometry_history: {
        Row: {
          geometry_hash: string
          id: string
          paddock_id: string
          polygon_points: Json
          recorded_at: string
          row_width: number | null
          rows: Json
          valid_from: string
          valid_to: string | null
          vineyard_id: string
        }
        Insert: {
          geometry_hash: string
          id?: string
          paddock_id: string
          polygon_points: Json
          recorded_at?: string
          row_width?: number | null
          rows: Json
          valid_from?: string
          valid_to?: string | null
          vineyard_id: string
        }
        Update: {
          geometry_hash?: string
          id?: string
          paddock_id?: string
          polygon_points?: Json
          recorded_at?: string
          row_width?: number | null
          rows?: Json
          valid_from?: string
          valid_to?: string | null
          vineyard_id?: string
        }
        Relationships: []
      }
      pin_row_backfill_approvals: {
        Row: {
          confirmed_at: string | null
          confirmed_by: string | null
          created_at: string
          created_by: string
          dry_run: Json
          id: string
          item_count: number
          items: Json
          items_hash: string
          receipts: Json | null
          status: string
          vineyard_id: string
        }
        Insert: {
          confirmed_at?: string | null
          confirmed_by?: string | null
          created_at?: string
          created_by: string
          dry_run: Json
          id?: string
          item_count: number
          items: Json
          items_hash: string
          receipts?: Json | null
          status?: string
          vineyard_id: string
        }
        Update: {
          confirmed_at?: string | null
          confirmed_by?: string | null
          created_at?: string
          created_by?: string
          dry_run?: Json
          id?: string
          item_count?: number
          items?: Json
          items_hash?: string
          receipts?: Json | null
          status?: string
          vineyard_id?: string
        }
        Relationships: []
      }
      pin_row_backfill_audit: {
        Row: {
          actor: string
          after: Json
          approval_id: string
          before: Json
          created_at: string
          decision_source: string
          id: string
          outcome: string
          pin_id: string
          projection: Json | null
          reason: string
          vineyard_id: string
        }
        Insert: {
          actor: string
          after: Json
          approval_id: string
          before: Json
          created_at?: string
          decision_source: string
          id?: string
          outcome: string
          pin_id: string
          projection?: Json | null
          reason: string
          vineyard_id: string
        }
        Update: {
          actor?: string
          after?: Json
          approval_id?: string
          before?: Json
          created_at?: string
          decision_source?: string
          id?: string
          outcome?: string
          pin_id?: string
          projection?: Json | null
          reason?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "pin_row_backfill_audit_approval_id_fkey"
            columns: ["approval_id"]
            isOneToOne: false
            referencedRelation: "pin_row_backfill_approvals"
            referencedColumns: ["id"]
          },
        ]
      }
      pin_row_segments: {
        Row: {
          pin_id: string
          row_number: number
          segment_number: number
        }
        Insert: {
          pin_id: string
          row_number: number
          segment_number: number
        }
        Update: {
          pin_id?: string
          row_number?: number
          segment_number?: number
        }
        Relationships: [
          {
            foreignKeyName: "pin_row_segments_pin_id_fkey"
            columns: ["pin_id"]
            isOneToOne: false
            referencedRelation: "manual_issues_export"
            referencedColumns: ["issue_id"]
          },
          {
            foreignKeyName: "pin_row_segments_pin_id_fkey"
            columns: ["pin_id"]
            isOneToOne: false
            referencedRelation: "pin_placements"
            referencedColumns: ["pin_id"]
          },
          {
            foreignKeyName: "pin_row_segments_pin_id_fkey"
            columns: ["pin_id"]
            isOneToOne: false
            referencedRelation: "pins"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pin_row_segments_pin_id_fkey"
            columns: ["pin_id"]
            isOneToOne: false
            referencedRelation: "pins_export"
            referencedColumns: ["pin_id"]
          },
          {
            foreignKeyName: "pin_row_segments_pin_id_fkey"
            columns: ["pin_id"]
            isOneToOne: false
            referencedRelation: "v_pin_attachment_preview"
            referencedColumns: ["pin_id"]
          },
        ]
      }
      pins: {
        Row: {
          along_row_distance_m: number | null
          assigned_user_id: string | null
          button_color: string | null
          button_name: string | null
          category: string | null
          client_updated_at: string | null
          completed_at: string | null
          completed_by: string | null
          completed_by_user_id: string | null
          created_at: string
          created_by: string | null
          custom_type_id: string | null
          deleted_at: string | null
          driving_row_number: number | null
          due_date: string | null
          growth_stage_code: string | null
          heading: number | null
          id: string
          is_completed: boolean
          latitude: number | null
          launcher_button_id: string | null
          linked_work_task_id: string | null
          location_confirmation_revision: number | null
          location_confirmed_at: string | null
          location_confirmed_by: string | null
          location_enriched_at: string | null
          location_enrichment_revision: number | null
          location_enrichment_status: string | null
          location_resolver_version: string | null
          location_scope: string | null
          longitude: number | null
          mode: string | null
          notes: string | null
          paddock_id: string | null
          photo_path: string | null
          pin_row_number: number | null
          pin_side: string | null
          priority: string | null
          row_number: number | null
          side: string | null
          snapped_latitude: number | null
          snapped_longitude: number | null
          snapped_to_row: boolean
          status: string | null
          sync_version: number
          title: string | null
          trip_id: string | null
          updated_at: string
          updated_by: string | null
          vineyard_id: string
        }
        Insert: {
          along_row_distance_m?: number | null
          assigned_user_id?: string | null
          button_color?: string | null
          button_name?: string | null
          category?: string | null
          client_updated_at?: string | null
          completed_at?: string | null
          completed_by?: string | null
          completed_by_user_id?: string | null
          created_at?: string
          created_by?: string | null
          custom_type_id?: string | null
          deleted_at?: string | null
          driving_row_number?: number | null
          due_date?: string | null
          growth_stage_code?: string | null
          heading?: number | null
          id?: string
          is_completed?: boolean
          latitude?: number | null
          launcher_button_id?: string | null
          linked_work_task_id?: string | null
          location_confirmation_revision?: number | null
          location_confirmed_at?: string | null
          location_confirmed_by?: string | null
          location_enriched_at?: string | null
          location_enrichment_revision?: number | null
          location_enrichment_status?: string | null
          location_resolver_version?: string | null
          location_scope?: string | null
          longitude?: number | null
          mode?: string | null
          notes?: string | null
          paddock_id?: string | null
          photo_path?: string | null
          pin_row_number?: number | null
          pin_side?: string | null
          priority?: string | null
          row_number?: number | null
          side?: string | null
          snapped_latitude?: number | null
          snapped_longitude?: number | null
          snapped_to_row?: boolean
          status?: string | null
          sync_version?: number
          title?: string | null
          trip_id?: string | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
        }
        Update: {
          along_row_distance_m?: number | null
          assigned_user_id?: string | null
          button_color?: string | null
          button_name?: string | null
          category?: string | null
          client_updated_at?: string | null
          completed_at?: string | null
          completed_by?: string | null
          completed_by_user_id?: string | null
          created_at?: string
          created_by?: string | null
          custom_type_id?: string | null
          deleted_at?: string | null
          driving_row_number?: number | null
          due_date?: string | null
          growth_stage_code?: string | null
          heading?: number | null
          id?: string
          is_completed?: boolean
          latitude?: number | null
          launcher_button_id?: string | null
          linked_work_task_id?: string | null
          location_confirmation_revision?: number | null
          location_confirmed_at?: string | null
          location_confirmed_by?: string | null
          location_enriched_at?: string | null
          location_enrichment_revision?: number | null
          location_enrichment_status?: string | null
          location_resolver_version?: string | null
          location_scope?: string | null
          longitude?: number | null
          mode?: string | null
          notes?: string | null
          paddock_id?: string | null
          photo_path?: string | null
          pin_row_number?: number | null
          pin_side?: string | null
          priority?: string | null
          row_number?: number | null
          side?: string | null
          snapped_latitude?: number | null
          snapped_longitude?: number | null
          snapped_to_row?: boolean
          status?: string | null
          sync_version?: number
          title?: string | null
          trip_id?: string | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "pins_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      product_nutrient_analysis: {
        Row: {
          analysis_basis: string
          concentration_basis: string
          created_at: string
          declared_as: string
          deleted_at: string | null
          display_name: string
          id: string
          is_primary: boolean
          nutrient_key: string
          percent: number
          product_id: string
          source_kind: string
          source_reference: string | null
          updated_at: string
        }
        Insert: {
          analysis_basis: string
          concentration_basis: string
          created_at?: string
          declared_as: string
          deleted_at?: string | null
          display_name: string
          id?: string
          is_primary?: boolean
          nutrient_key: string
          percent: number
          product_id: string
          source_kind?: string
          source_reference?: string | null
          updated_at?: string
        }
        Update: {
          analysis_basis?: string
          concentration_basis?: string
          created_at?: string
          declared_as?: string
          deleted_at?: string | null
          display_name?: string
          id?: string
          is_primary?: boolean
          nutrient_key?: string
          percent?: number
          product_id?: string
          source_kind?: string
          source_reference?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "product_nutrient_analysis_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "saved_chemical_intelligence_audit"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "product_nutrient_analysis_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "saved_chemicals"
            referencedColumns: ["id"]
          },
        ]
      }
      profiles: {
        Row: {
          avatar_url: string | null
          created_at: string
          default_vineyard_id: string | null
          email: string
          full_name: string | null
          id: string
          updated_at: string
        }
        Insert: {
          avatar_url?: string | null
          created_at?: string
          default_vineyard_id?: string | null
          email: string
          full_name?: string | null
          id: string
          updated_at?: string
        }
        Update: {
          avatar_url?: string | null
          created_at?: string
          default_vineyard_id?: string | null
          email?: string
          full_name?: string | null
          id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "profiles_default_vineyard_id_fkey"
            columns: ["default_vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      pruning_activities: {
        Row: {
          allocation_count: number
          block_summary: string
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          entry_date: string
          external_resource_id: string | null
          finish_time: string | null
          hourly_rate: number | null
          id: string
          is_skipped: boolean
          labour_hours: number | null
          notes: string
          pruning_method: string
          season_year: number | null
          start_time: string | null
          sync_version: number
          total_estimated_vines: number
          total_quarters: number
          total_row_equivalents: number
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          vintage_year: number | null
          work_task_id: string | null
          worker_or_crew: string
          worker_user_id: string | null
        }
        Insert: {
          allocation_count?: number
          block_summary?: string
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          entry_date: string
          external_resource_id?: string | null
          finish_time?: string | null
          hourly_rate?: number | null
          id: string
          is_skipped?: boolean
          labour_hours?: number | null
          notes?: string
          pruning_method?: string
          season_year?: number | null
          start_time?: string | null
          sync_version?: number
          total_estimated_vines?: number
          total_quarters?: number
          total_row_equivalents?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
          vintage_year?: number | null
          work_task_id?: string | null
          worker_or_crew?: string
          worker_user_id?: string | null
        }
        Update: {
          allocation_count?: number
          block_summary?: string
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          entry_date?: string
          external_resource_id?: string | null
          finish_time?: string | null
          hourly_rate?: number | null
          id?: string
          is_skipped?: boolean
          labour_hours?: number | null
          notes?: string
          pruning_method?: string
          season_year?: number | null
          start_time?: string | null
          sync_version?: number
          total_estimated_vines?: number
          total_quarters?: number
          total_row_equivalents?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
          vintage_year?: number | null
          work_task_id?: string | null
          worker_or_crew?: string
          worker_user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "pruning_activities_external_resource_id_fkey"
            columns: ["external_resource_id"]
            isOneToOne: false
            referencedRelation: "vineyard_external_resources"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pruning_activities_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pruning_activities_worker_user_id_fkey"
            columns: ["worker_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      pruning_activity_labour_lines: {
        Row: {
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          hourly_rate: number | null
          hours_per_worker: number
          id: string
          line_index: number
          notes: string
          pruning_activity_id: string
          sync_version: number
          total_cost: number | null
          total_hours: number | null
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          work_date: string
          worker_count: number
          worker_type: string
          worker_type_id: string | null
        }
        Insert: {
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          hourly_rate?: number | null
          hours_per_worker?: number
          id: string
          line_index?: number
          notes?: string
          pruning_activity_id: string
          sync_version?: number
          total_cost?: number | null
          total_hours?: number | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
          work_date: string
          worker_count?: number
          worker_type?: string
          worker_type_id?: string | null
        }
        Update: {
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          hourly_rate?: number | null
          hours_per_worker?: number
          id?: string
          line_index?: number
          notes?: string
          pruning_activity_id?: string
          sync_version?: number
          total_cost?: number | null
          total_hours?: number | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
          work_date?: string
          worker_count?: number
          worker_type?: string
          worker_type_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "pruning_activity_labour_lines_pruning_activity_id_fkey"
            columns: ["pruning_activity_id"]
            isOneToOne: false
            referencedRelation: "pruning_activities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pruning_activity_labour_lines_pruning_activity_id_fkey"
            columns: ["pruning_activity_id"]
            isOneToOne: false
            referencedRelation: "pruning_activity_allocation_export"
            referencedColumns: ["activity_id"]
          },
          {
            foreignKeyName: "pruning_activity_labour_lines_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      pruning_entries: {
        Row: {
          allocation_index: number
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          entry_date: string
          estimated_vines_completed: number
          finish_time: string | null
          id: string
          is_skipped: boolean
          labour_hours: number | null
          notes: string
          paddock_id: string
          pruning_activity_id: string | null
          pruning_method: string
          pruning_season_id: string
          row_equivalents_completed: number
          start_time: string | null
          sync_version: number
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          vintage_year: number | null
          work_task_id: string | null
          worker_or_crew: string
        }
        Insert: {
          allocation_index?: number
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          entry_date: string
          estimated_vines_completed?: number
          finish_time?: string | null
          id: string
          is_skipped?: boolean
          labour_hours?: number | null
          notes?: string
          paddock_id: string
          pruning_activity_id?: string | null
          pruning_method?: string
          pruning_season_id: string
          row_equivalents_completed?: number
          start_time?: string | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
          vintage_year?: number | null
          work_task_id?: string | null
          worker_or_crew?: string
        }
        Update: {
          allocation_index?: number
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          entry_date?: string
          estimated_vines_completed?: number
          finish_time?: string | null
          id?: string
          is_skipped?: boolean
          labour_hours?: number | null
          notes?: string
          paddock_id?: string
          pruning_activity_id?: string | null
          pruning_method?: string
          pruning_season_id?: string
          row_equivalents_completed?: number
          start_time?: string | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
          vintage_year?: number | null
          work_task_id?: string | null
          worker_or_crew?: string
        }
        Relationships: [
          {
            foreignKeyName: "pruning_entries_pruning_season_id_fkey"
            columns: ["pruning_season_id"]
            isOneToOne: false
            referencedRelation: "pruning_seasons"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pruning_entries_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      pruning_entry_audit: {
        Row: {
          created_at: string
          created_by: string | null
          detail: Json | null
          event_type: string
          id: string
          new_labour_hours: number | null
          new_quarters: number | null
          previous_labour_hours: number | null
          previous_quarters: number | null
          pruning_entry_id: string
          vineyard_id: string
          work_task_changed: boolean
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          detail?: Json | null
          event_type: string
          id?: string
          new_labour_hours?: number | null
          new_quarters?: number | null
          previous_labour_hours?: number | null
          previous_quarters?: number | null
          pruning_entry_id: string
          vineyard_id: string
          work_task_changed?: boolean
        }
        Update: {
          created_at?: string
          created_by?: string | null
          detail?: Json | null
          event_type?: string
          id?: string
          new_labour_hours?: number | null
          new_quarters?: number | null
          previous_labour_hours?: number | null
          previous_quarters?: number | null
          pruning_entry_id?: string
          vineyard_id?: string
          work_task_changed?: boolean
        }
        Relationships: [
          {
            foreignKeyName: "pruning_entry_audit_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      pruning_row_segments: {
        Row: {
          completed: boolean
          completed_at: string | null
          completed_by: string | null
          created_at: string
          id: string
          paddock_id: string
          paddock_row_id: string | null
          pruning_entry_id: string | null
          pruning_season_id: string
          row_label: string | null
          row_number: number
          segment_number: number
          updated_at: string
          vineyard_id: string
        }
        Insert: {
          completed?: boolean
          completed_at?: string | null
          completed_by?: string | null
          created_at?: string
          id?: string
          paddock_id: string
          paddock_row_id?: string | null
          pruning_entry_id?: string | null
          pruning_season_id: string
          row_label?: string | null
          row_number: number
          segment_number: number
          updated_at?: string
          vineyard_id: string
        }
        Update: {
          completed?: boolean
          completed_at?: string | null
          completed_by?: string | null
          created_at?: string
          id?: string
          paddock_id?: string
          paddock_row_id?: string | null
          pruning_entry_id?: string | null
          pruning_season_id?: string
          row_label?: string | null
          row_number?: number
          segment_number?: number
          updated_at?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "pruning_row_segments_pruning_season_id_fkey"
            columns: ["pruning_season_id"]
            isOneToOne: false
            referencedRelation: "pruning_seasons"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pruning_row_segments_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      pruning_season_backfill_log: {
        Row: {
          entry_date: string
          entry_reversed: boolean
          id: string
          new_season_id: string
          new_season_year: number
          paddock_id: string
          previous_season_id: string
          previous_season_year: number | null
          pruning_entry_id: string
          quarters_after: number
          quarters_before: number
          quarters_released: number
          ran_at: string
          ran_by: string | null
          vineyard_id: string
        }
        Insert: {
          entry_date: string
          entry_reversed?: boolean
          id?: string
          new_season_id: string
          new_season_year: number
          paddock_id: string
          previous_season_id: string
          previous_season_year?: number | null
          pruning_entry_id: string
          quarters_after?: number
          quarters_before?: number
          quarters_released?: number
          ran_at?: string
          ran_by?: string | null
          vineyard_id: string
        }
        Update: {
          entry_date?: string
          entry_reversed?: boolean
          id?: string
          new_season_id?: string
          new_season_year?: number
          paddock_id?: string
          previous_season_id?: string
          previous_season_year?: number | null
          pruning_entry_id?: string
          quarters_after?: number
          quarters_before?: number
          quarters_released?: number
          ran_at?: string
          ran_by?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "pruning_season_backfill_log_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      pruning_season_mismatch_log: {
        Row: {
          actor: string | null
          canonical_season_id: string
          canonical_season_year: number
          entry_date: string
          first_seen_at: string
          id: number
          last_seen_at: string
          occurrences: number
          paddock_id: string
          submitted_season_id: string
          submitted_season_year: number | null
          vineyard_id: string
        }
        Insert: {
          actor?: string | null
          canonical_season_id: string
          canonical_season_year: number
          entry_date: string
          first_seen_at?: string
          id?: number
          last_seen_at?: string
          occurrences?: number
          paddock_id: string
          submitted_season_id: string
          submitted_season_year?: number | null
          vineyard_id: string
        }
        Update: {
          actor?: string | null
          canonical_season_id?: string
          canonical_season_year?: number
          entry_date?: string
          first_seen_at?: string
          id?: number
          last_seen_at?: string
          occurrences?: number
          paddock_id?: string
          submitted_season_id?: string
          submitted_season_year?: number | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "pruning_season_mismatch_log_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      pruning_seasons: {
        Row: {
          assigned_crew: string
          base_revision: number | null
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          due_date: string | null
          estimated_labour_hours: number | null
          id: string
          manual_row_count: number | null
          notes: string
          paddock_id: string
          pruning_method: string
          season_year: number
          server_revision: number
          start_date: string | null
          status: string
          sync_version: number
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          working_days: number[]
        }
        Insert: {
          assigned_crew?: string
          base_revision?: number | null
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          due_date?: string | null
          estimated_labour_hours?: number | null
          id: string
          manual_row_count?: number | null
          notes?: string
          paddock_id: string
          pruning_method?: string
          season_year: number
          server_revision?: number
          start_date?: string | null
          status?: string
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
          working_days?: number[]
        }
        Update: {
          assigned_crew?: string
          base_revision?: number | null
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          due_date?: string | null
          estimated_labour_hours?: number | null
          id?: string
          manual_row_count?: number | null
          notes?: string
          paddock_id?: string
          pruning_method?: string
          season_year?: number
          server_revision?: number
          start_date?: string | null
          status?: string
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
          working_days?: number[]
        }
        Relationships: [
          {
            foreignKeyName: "pruning_seasons_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      pruning_yield_settings: {
        Row: {
          base_revision: number | null
          buds_per_cane: number
          buds_per_spur: number
          bunch_weight_grams: number
          bunches_per_bud: number
          canes_per_vine: number
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          paddock_id: string
          prune_method: string
          server_revision: number
          spurs_per_vine: number
          sync_version: number
          updated_at: string
          updated_by: string | null
          vines_per_ha: number | null
          vineyard_id: string
        }
        Insert: {
          base_revision?: number | null
          buds_per_cane?: number
          buds_per_spur?: number
          bunch_weight_grams?: number
          bunches_per_bud?: number
          canes_per_vine?: number
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          paddock_id: string
          prune_method?: string
          server_revision?: number
          spurs_per_vine?: number
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vines_per_ha?: number | null
          vineyard_id: string
        }
        Update: {
          base_revision?: number | null
          buds_per_cane?: number
          buds_per_spur?: number
          bunch_weight_grams?: number
          bunches_per_bud?: number
          canes_per_vine?: number
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          paddock_id?: string
          prune_method?: string
          server_revision?: number
          spurs_per_vine?: number
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vines_per_ha?: number | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "pruning_yield_settings_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      rainfall_daily: {
        Row: {
          created_at: string
          created_by: string | null
          date: string
          deleted_at: string | null
          id: string
          notes: string | null
          rainfall_mm: number
          source: string
          station_id: string | null
          station_name: string | null
          updated_at: string
          updated_by: string | null
          vineyard_id: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          date: string
          deleted_at?: string | null
          id?: string
          notes?: string | null
          rainfall_mm: number
          source: string
          station_id?: string | null
          station_name?: string | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          date?: string
          deleted_at?: string | null
          id?: string
          notes?: string | null
          rainfall_mm?: number
          source?: string
          station_id?: string | null
          station_name?: string | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "rainfall_daily_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      resistance_plans: {
        Row: {
          base_revision: number | null
          block_ids: string[] | null
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          crop: string
          deleted_at: string | null
          disease: string
          id: string
          jurisdiction: string
          notes: string | null
          positions: Json
          ruleset_id: string | null
          ruleset_version: string | null
          season_id: string
          season_start_year: number | null
          server_revision: number
          sync_version: number
          updated_at: string
          updated_by: string | null
          vineyard_id: string
        }
        Insert: {
          base_revision?: number | null
          block_ids?: string[] | null
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          crop?: string
          deleted_at?: string | null
          disease: string
          id?: string
          jurisdiction?: string
          notes?: string | null
          positions?: Json
          ruleset_id?: string | null
          ruleset_version?: string | null
          season_id: string
          season_start_year?: number | null
          server_revision?: number
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
        }
        Update: {
          base_revision?: number | null
          block_ids?: string[] | null
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          crop?: string
          deleted_at?: string | null
          disease?: string
          id?: string
          jurisdiction?: string
          notes?: string | null
          positions?: Json
          ruleset_id?: string | null
          ruleset_version?: string | null
          season_id?: string
          season_start_year?: number | null
          server_revision?: number
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "resistance_plans_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      rootstock_catalog: {
        Row: {
          aliases: Json
          canonical_name: string
          created_at: string
          display_name: string
          is_active: boolean
          is_builtin: boolean
          key: string
          parentage: string | null
          source_reference: string | null
          updated_at: string
        }
        Insert: {
          aliases?: Json
          canonical_name: string
          created_at?: string
          display_name: string
          is_active?: boolean
          is_builtin?: boolean
          key: string
          parentage?: string | null
          source_reference?: string | null
          updated_at?: string
        }
        Update: {
          aliases?: Json
          canonical_name?: string
          created_at?: string
          display_name?: string
          is_active?: boolean
          is_builtin?: boolean
          key?: string
          parentage?: string | null
          source_reference?: string | null
          updated_at?: string
        }
        Relationships: []
      }
      saved_chemical_attachments: {
        Row: {
          created_at: string
          created_by: string
          deleted_at: string | null
          id: string
          kind: string
          saved_chemical_id: string
          status: string
          storage_path: string
          vineyard_id: string
        }
        Insert: {
          created_at?: string
          created_by?: string
          deleted_at?: string | null
          id?: string
          kind?: string
          saved_chemical_id: string
          status?: string
          storage_path: string
          vineyard_id: string
        }
        Update: {
          created_at?: string
          created_by?: string
          deleted_at?: string | null
          id?: string
          kind?: string
          saved_chemical_id?: string
          status?: string
          storage_path?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "saved_chemical_attachments_saved_chemical_id_fkey"
            columns: ["saved_chemical_id"]
            isOneToOne: false
            referencedRelation: "saved_chemical_intelligence_audit"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "saved_chemical_attachments_saved_chemical_id_fkey"
            columns: ["saved_chemical_id"]
            isOneToOne: false
            referencedRelation: "saved_chemicals"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "saved_chemical_attachments_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      saved_chemicals: {
        Row: {
          active_ingredient: string
          active_ingredients: Json | null
          activity_group_scheme: string | null
          activity_group_table_version: number | null
          activity_groups: string[] | null
          analysis_basis: string
          application_notes: string
          chemical_group: string
          chemical_v3_product_id: string | null
          chemical_v3_review_status_snapshot: string | null
          chemical_v3_revision_id: string | null
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          crop: string
          default_rates: Json | null
          deleted_at: string | null
          density: number | null
          entry_source: string | null
          id: string
          intelligence_schema_version: number
          inventory_quantity: number | null
          inventory_unit: string
          is_active: boolean
          label_rate_bases: string[] | null
          label_reference: string | null
          label_url: string
          label_version: string | null
          manufacturer: string
          master_chemical_id: string | null
          master_source_revision: number | null
          mode_of_action: string
          name: string
          nitrogen_percent: number | null
          notes: string
          organic_certified: boolean
          pack_size: number | null
          pack_unit: string
          phosphorus_percent: number | null
          potassium_percent: number | null
          price_per_pack: number | null
          problem: string
          product_category: string
          product_form: string
          product_url: string
          purchase: Json | null
          rate_per_ha: number | null
          rates: Json | null
          registered_product_name: string | null
          registered_uses: Json | null
          registrant: string | null
          registration_country: string | null
          registration_number: string | null
          registration_scheme: string | null
          resistance_classification_state: string
          restrictions: string
          sync_version: number
          unit: string
          updated_at: string
          updated_by: string | null
          use: string
          verification_conflicts: Json | null
          verification_sources: Json | null
          verification_status: string
          verification_unresolved_fields: string[] | null
          verified_at: string | null
          vineyard_id: string
          vineyard_preferred_rate: Json | null
        }
        Insert: {
          active_ingredient?: string
          active_ingredients?: Json | null
          activity_group_scheme?: string | null
          activity_group_table_version?: number | null
          activity_groups?: string[] | null
          analysis_basis?: string
          application_notes?: string
          chemical_group?: string
          chemical_v3_product_id?: string | null
          chemical_v3_review_status_snapshot?: string | null
          chemical_v3_revision_id?: string | null
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          crop?: string
          default_rates?: Json | null
          deleted_at?: string | null
          density?: number | null
          entry_source?: string | null
          id?: string
          intelligence_schema_version?: number
          inventory_quantity?: number | null
          inventory_unit?: string
          is_active?: boolean
          label_rate_bases?: string[] | null
          label_reference?: string | null
          label_url?: string
          label_version?: string | null
          manufacturer?: string
          master_chemical_id?: string | null
          master_source_revision?: number | null
          mode_of_action?: string
          name?: string
          nitrogen_percent?: number | null
          notes?: string
          organic_certified?: boolean
          pack_size?: number | null
          pack_unit?: string
          phosphorus_percent?: number | null
          potassium_percent?: number | null
          price_per_pack?: number | null
          problem?: string
          product_category?: string
          product_form?: string
          product_url?: string
          purchase?: Json | null
          rate_per_ha?: number | null
          rates?: Json | null
          registered_product_name?: string | null
          registered_uses?: Json | null
          registrant?: string | null
          registration_country?: string | null
          registration_number?: string | null
          registration_scheme?: string | null
          resistance_classification_state?: string
          restrictions?: string
          sync_version?: number
          unit?: string
          updated_at?: string
          updated_by?: string | null
          use?: string
          verification_conflicts?: Json | null
          verification_sources?: Json | null
          verification_status?: string
          verification_unresolved_fields?: string[] | null
          verified_at?: string | null
          vineyard_id: string
          vineyard_preferred_rate?: Json | null
        }
        Update: {
          active_ingredient?: string
          active_ingredients?: Json | null
          activity_group_scheme?: string | null
          activity_group_table_version?: number | null
          activity_groups?: string[] | null
          analysis_basis?: string
          application_notes?: string
          chemical_group?: string
          chemical_v3_product_id?: string | null
          chemical_v3_review_status_snapshot?: string | null
          chemical_v3_revision_id?: string | null
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          crop?: string
          default_rates?: Json | null
          deleted_at?: string | null
          density?: number | null
          entry_source?: string | null
          id?: string
          intelligence_schema_version?: number
          inventory_quantity?: number | null
          inventory_unit?: string
          is_active?: boolean
          label_rate_bases?: string[] | null
          label_reference?: string | null
          label_url?: string
          label_version?: string | null
          manufacturer?: string
          master_chemical_id?: string | null
          master_source_revision?: number | null
          mode_of_action?: string
          name?: string
          nitrogen_percent?: number | null
          notes?: string
          organic_certified?: boolean
          pack_size?: number | null
          pack_unit?: string
          phosphorus_percent?: number | null
          potassium_percent?: number | null
          price_per_pack?: number | null
          problem?: string
          product_category?: string
          product_form?: string
          product_url?: string
          purchase?: Json | null
          rate_per_ha?: number | null
          rates?: Json | null
          registered_product_name?: string | null
          registered_uses?: Json | null
          registrant?: string | null
          registration_country?: string | null
          registration_number?: string | null
          registration_scheme?: string | null
          resistance_classification_state?: string
          restrictions?: string
          sync_version?: number
          unit?: string
          updated_at?: string
          updated_by?: string | null
          use?: string
          verification_conflicts?: Json | null
          verification_sources?: Json | null
          verification_status?: string
          verification_unresolved_fields?: string[] | null
          verified_at?: string | null
          vineyard_id?: string
          vineyard_preferred_rate?: Json | null
        }
        Relationships: [
          {
            foreignKeyName: "saved_chemicals_master_chemical_id_fkey"
            columns: ["master_chemical_id"]
            isOneToOne: false
            referencedRelation: "master_chemicals"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "saved_chemicals_v3_product_fk"
            columns: ["chemical_v3_product_id"]
            isOneToOne: false
            referencedRelation: "chemical_v3_products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "saved_chemicals_v3_revision_fk"
            columns: ["chemical_v3_revision_id"]
            isOneToOne: false
            referencedRelation: "chemical_v3_product_revisions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "saved_chemicals_v3_revision_fk"
            columns: ["chemical_v3_revision_id"]
            isOneToOne: false
            referencedRelation: "saved_chemicals_effective"
            referencedColumns: ["effective_catalogue_revision_id"]
          },
          {
            foreignKeyName: "saved_chemicals_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      saved_inputs: {
        Row: {
          client_updated_at: string | null
          cost_per_unit: number | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          input_type: string
          name: string
          notes: string | null
          supplier: string | null
          sync_version: number
          unit: string
          updated_at: string
          updated_by: string | null
          vineyard_id: string
        }
        Insert: {
          client_updated_at?: string | null
          cost_per_unit?: number | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          input_type?: string
          name?: string
          notes?: string | null
          supplier?: string | null
          sync_version?: number
          unit?: string
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
        }
        Update: {
          client_updated_at?: string | null
          cost_per_unit?: number | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          input_type?: string
          name?: string
          notes?: string | null
          supplier?: string | null
          sync_version?: number
          unit?: string
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "saved_inputs_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      saved_spray_presets: {
        Row: {
          client_updated_at: string | null
          concentration_factor: number
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          name: string
          spray_rate_per_ha: number
          sync_version: number
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          water_volume: number
        }
        Insert: {
          client_updated_at?: string | null
          concentration_factor?: number
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          name?: string
          spray_rate_per_ha?: number
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
          water_volume?: number
        }
        Update: {
          client_updated_at?: string | null
          concentration_factor?: number
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          name?: string
          spray_rate_per_ha?: number
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
          water_volume?: number
        }
        Relationships: [
          {
            foreignKeyName: "saved_spray_presets_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      scout_block_assessments: {
        Row: {
          client_revision_id: string | null
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          paddock_id: string
          scout_visit_id: string
          status: string
          stop_context: Json | null
          sync_version: number
          updated_at: string
          updated_by: string | null
          vineyard_id: string
        }
        Insert: {
          client_revision_id?: string | null
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id: string
          paddock_id: string
          scout_visit_id: string
          status?: string
          stop_context?: Json | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
        }
        Update: {
          client_revision_id?: string | null
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          paddock_id?: string
          scout_visit_id?: string
          status?: string
          stop_context?: Json | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "insights_assessment_block_tenant_fk"
            columns: ["paddock_id", "vineyard_id"]
            isOneToOne: false
            referencedRelation: "paddocks"
            referencedColumns: ["id", "vineyard_id"]
          },
          {
            foreignKeyName: "insights_assessment_visit_tenant_fk"
            columns: ["scout_visit_id", "vineyard_id"]
            isOneToOne: false
            referencedRelation: "scout_visits"
            referencedColumns: ["id", "vineyard_id"]
          },
          {
            foreignKeyName: "scout_block_assessments_paddock_id_fkey"
            columns: ["paddock_id"]
            isOneToOne: false
            referencedRelation: "paddocks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "scout_block_assessments_scout_visit_id_fkey"
            columns: ["scout_visit_id"]
            isOneToOne: false
            referencedRelation: "scout_visits"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "scout_block_assessments_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      scout_observation_photos: {
        Row: {
          captured_at: string
          captured_by: string | null
          client_revision_id: string | null
          client_updated_at: string | null
          created_at: string
          deleted_at: string | null
          horizontal_accuracy: number | null
          id: string
          latitude: number | null
          location_status: string
          longitude: number | null
          observation_id: string
          storage_path: string
          sync_version: number
          updated_at: string
          vineyard_id: string
        }
        Insert: {
          captured_at: string
          captured_by?: string | null
          client_revision_id?: string | null
          client_updated_at?: string | null
          created_at?: string
          deleted_at?: string | null
          horizontal_accuracy?: number | null
          id: string
          latitude?: number | null
          location_status?: string
          longitude?: number | null
          observation_id: string
          storage_path: string
          sync_version?: number
          updated_at?: string
          vineyard_id: string
        }
        Update: {
          captured_at?: string
          captured_by?: string | null
          client_revision_id?: string | null
          client_updated_at?: string | null
          created_at?: string
          deleted_at?: string | null
          horizontal_accuracy?: number | null
          id?: string
          latitude?: number | null
          location_status?: string
          longitude?: number | null
          observation_id?: string
          storage_path?: string
          sync_version?: number
          updated_at?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "insights_photo_observation_tenant_fk"
            columns: ["observation_id", "vineyard_id"]
            isOneToOne: false
            referencedRelation: "scout_observations"
            referencedColumns: ["id", "vineyard_id"]
          },
          {
            foreignKeyName: "scout_observation_photos_observation_id_fkey"
            columns: ["observation_id"]
            isOneToOne: false
            referencedRelation: "scout_observations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "scout_observation_photos_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      scout_observations: {
        Row: {
          assessment_id: string
          client_revision_id: string | null
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          horizontal_accuracy: number | null
          id: string
          item_kind: string
          latitude: number | null
          linked_growth_record_id: string | null
          linked_pin_id: string | null
          location_captured_at: string | null
          location_status: string
          longitude: number | null
          notes: string | null
          sync_version: number
          updated_at: string
          updated_by: string | null
          value_code: string | null
          value_label: string | null
          vineyard_id: string
        }
        Insert: {
          assessment_id: string
          client_revision_id?: string | null
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          horizontal_accuracy?: number | null
          id: string
          item_kind: string
          latitude?: number | null
          linked_growth_record_id?: string | null
          linked_pin_id?: string | null
          location_captured_at?: string | null
          location_status?: string
          longitude?: number | null
          notes?: string | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          value_code?: string | null
          value_label?: string | null
          vineyard_id: string
        }
        Update: {
          assessment_id?: string
          client_revision_id?: string | null
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          horizontal_accuracy?: number | null
          id?: string
          item_kind?: string
          latitude?: number | null
          linked_growth_record_id?: string | null
          linked_pin_id?: string | null
          location_captured_at?: string | null
          location_status?: string
          longitude?: number | null
          notes?: string | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          value_code?: string | null
          value_label?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "insights_observation_assessment_tenant_fk"
            columns: ["assessment_id", "vineyard_id"]
            isOneToOne: false
            referencedRelation: "scout_block_assessments"
            referencedColumns: ["id", "vineyard_id"]
          },
          {
            foreignKeyName: "insights_observation_growth_tenant_fk"
            columns: ["linked_growth_record_id", "vineyard_id"]
            isOneToOne: false
            referencedRelation: "growth_stage_records"
            referencedColumns: ["id", "vineyard_id"]
          },
          {
            foreignKeyName: "insights_observation_pin_tenant_fk"
            columns: ["linked_pin_id", "vineyard_id"]
            isOneToOne: false
            referencedRelation: "manual_issues_export"
            referencedColumns: ["issue_id", "vineyard_id"]
          },
          {
            foreignKeyName: "insights_observation_pin_tenant_fk"
            columns: ["linked_pin_id", "vineyard_id"]
            isOneToOne: false
            referencedRelation: "pin_placements"
            referencedColumns: ["pin_id", "vineyard_id"]
          },
          {
            foreignKeyName: "insights_observation_pin_tenant_fk"
            columns: ["linked_pin_id", "vineyard_id"]
            isOneToOne: false
            referencedRelation: "pins"
            referencedColumns: ["id", "vineyard_id"]
          },
          {
            foreignKeyName: "insights_observation_pin_tenant_fk"
            columns: ["linked_pin_id", "vineyard_id"]
            isOneToOne: false
            referencedRelation: "pins_export"
            referencedColumns: ["pin_id", "vineyard_id"]
          },
          {
            foreignKeyName: "insights_observation_pin_tenant_fk"
            columns: ["linked_pin_id", "vineyard_id"]
            isOneToOne: false
            referencedRelation: "v_pin_attachment_preview"
            referencedColumns: ["pin_id", "vineyard_id"]
          },
          {
            foreignKeyName: "scout_observations_assessment_id_fkey"
            columns: ["assessment_id"]
            isOneToOne: false
            referencedRelation: "scout_block_assessments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "scout_observations_linked_growth_record_id_fkey"
            columns: ["linked_growth_record_id"]
            isOneToOne: false
            referencedRelation: "growth_stage_records"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "scout_observations_linked_pin_id_fkey"
            columns: ["linked_pin_id"]
            isOneToOne: false
            referencedRelation: "manual_issues_export"
            referencedColumns: ["issue_id"]
          },
          {
            foreignKeyName: "scout_observations_linked_pin_id_fkey"
            columns: ["linked_pin_id"]
            isOneToOne: false
            referencedRelation: "pin_placements"
            referencedColumns: ["pin_id"]
          },
          {
            foreignKeyName: "scout_observations_linked_pin_id_fkey"
            columns: ["linked_pin_id"]
            isOneToOne: false
            referencedRelation: "pins"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "scout_observations_linked_pin_id_fkey"
            columns: ["linked_pin_id"]
            isOneToOne: false
            referencedRelation: "pins_export"
            referencedColumns: ["pin_id"]
          },
          {
            foreignKeyName: "scout_observations_linked_pin_id_fkey"
            columns: ["linked_pin_id"]
            isOneToOne: false
            referencedRelation: "v_pin_attachment_preview"
            referencedColumns: ["pin_id"]
          },
          {
            foreignKeyName: "scout_observations_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      scout_photo_cleanup_queue: {
        Row: {
          attempt_count: number
          completed_at: string | null
          created_at: string
          id: string
          last_error: string | null
          lease_expires_at: string | null
          lease_token: string | null
          leased_at: string | null
          next_attempt_at: string
          photo_id: string
          scout_visit_id: string
          status: string
          storage_path: string
          vineyard_id: string
        }
        Insert: {
          attempt_count?: number
          completed_at?: string | null
          created_at?: string
          id?: string
          last_error?: string | null
          lease_expires_at?: string | null
          lease_token?: string | null
          leased_at?: string | null
          next_attempt_at?: string
          photo_id: string
          scout_visit_id: string
          status?: string
          storage_path: string
          vineyard_id: string
        }
        Update: {
          attempt_count?: number
          completed_at?: string | null
          created_at?: string
          id?: string
          last_error?: string | null
          lease_expires_at?: string | null
          lease_token?: string | null
          leased_at?: string | null
          next_attempt_at?: string
          photo_id?: string
          scout_visit_id?: string
          status?: string
          storage_path?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "scout_photo_cleanup_queue_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      scout_visits: {
        Row: {
          client_revision_id: string | null
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          scout_date: string
          scout_name_snapshot: string | null
          scout_user_id: string | null
          status: string
          sync_version: number
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          vintage_year: number
          visit_summary: string | null
          weather_snapshot: Json | null
        }
        Insert: {
          client_revision_id?: string | null
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id: string
          scout_date?: string
          scout_name_snapshot?: string | null
          scout_user_id?: string | null
          status?: string
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
          vintage_year: number
          visit_summary?: string | null
          weather_snapshot?: Json | null
        }
        Update: {
          client_revision_id?: string | null
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          scout_date?: string
          scout_name_snapshot?: string | null
          scout_user_id?: string | null
          status?: string
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
          vintage_year?: number
          visit_summary?: string | null
          weather_snapshot?: Json | null
        }
        Relationships: [
          {
            foreignKeyName: "scout_visits_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      season_yield_estimates: {
        Row: {
          allocation_percent: number
          base_estimate_tonnes: number | null
          calculated_at: string
          client_updated_at: string | null
          clone: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          estimate_source: string
          id: string
          is_estimate_available: boolean
          is_unallocated: boolean
          notes: string
          paddock_id: string
          planting_group_key: string
          rootstock: string | null
          setup_warnings: Json
          source_inputs: Json
          source_session_id: string | null
          sync_version: number
          updated_at: string
          updated_by: string | null
          variety_allocation_ids: string[] | null
          variety_key: string | null
          variety_name: string
          vineyard_id: string
          vintage: number
        }
        Insert: {
          allocation_percent?: number
          base_estimate_tonnes?: number | null
          calculated_at?: string
          client_updated_at?: string | null
          clone?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          estimate_source?: string
          id?: string
          is_estimate_available?: boolean
          is_unallocated?: boolean
          notes?: string
          paddock_id: string
          planting_group_key: string
          rootstock?: string | null
          setup_warnings?: Json
          source_inputs?: Json
          source_session_id?: string | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          variety_allocation_ids?: string[] | null
          variety_key?: string | null
          variety_name?: string
          vineyard_id: string
          vintage: number
        }
        Update: {
          allocation_percent?: number
          base_estimate_tonnes?: number | null
          calculated_at?: string
          client_updated_at?: string | null
          clone?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          estimate_source?: string
          id?: string
          is_estimate_available?: boolean
          is_unallocated?: boolean
          notes?: string
          paddock_id?: string
          planting_group_key?: string
          rootstock?: string | null
          setup_warnings?: Json
          source_inputs?: Json
          source_session_id?: string | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          variety_allocation_ids?: string[] | null
          variety_key?: string | null
          variety_name?: string
          vineyard_id?: string
          vintage?: number
        }
        Relationships: [
          {
            foreignKeyName: "season_yield_estimates_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      soil_analyte_catalogue: {
        Row: {
          canonical_unit: string | null
          category: string
          created_at: string
          description: string | null
          desired_direction: string
          display_name: string
          is_active: boolean
          key: string
          updated_at: string
        }
        Insert: {
          canonical_unit?: string | null
          category: string
          created_at?: string
          description?: string | null
          desired_direction?: string
          display_name: string
          is_active?: boolean
          key: string
          updated_at?: string
        }
        Update: {
          canonical_unit?: string | null
          category?: string
          created_at?: string
          description?: string | null
          desired_direction?: string
          display_name?: string
          is_active?: boolean
          key?: string
          updated_at?: string
        }
        Relationships: []
      }
      soil_block_aliases: {
        Row: {
          alias: string
          created_at: string
          created_by: string | null
          id: string
          normalized_alias: string
          paddock_id: string | null
          row_end: number | null
          row_start: number | null
          updated_at: string
          vineyard_id: string
        }
        Insert: {
          alias: string
          created_at?: string
          created_by?: string | null
          id?: string
          normalized_alias: string
          paddock_id?: string | null
          row_end?: number | null
          row_start?: number | null
          updated_at?: string
          vineyard_id: string
        }
        Update: {
          alias?: string
          created_at?: string
          created_by?: string | null
          id?: string
          normalized_alias?: string
          paddock_id?: string | null
          row_end?: number | null
          row_start?: number | null
          updated_at?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "soil_block_aliases_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "soil_block_aliases_paddock_id_fkey"
            columns: ["paddock_id"]
            isOneToOne: false
            referencedRelation: "paddocks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "soil_block_aliases_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      soil_class_defaults: {
        Row: {
          created_at: string
          default_allowed_depletion_percent: number
          default_awc_max_mm_per_m: number | null
          default_awc_min_mm_per_m: number | null
          default_awc_mm_per_m: number
          default_root_depth_m: number
          description: string | null
          drainage_risk: string | null
          infiltration_risk: string | null
          irrigation_soil_class: string
          label: string
          sort_order: number
          updated_at: string
          waterlogging_risk: string | null
        }
        Insert: {
          created_at?: string
          default_allowed_depletion_percent?: number
          default_awc_max_mm_per_m?: number | null
          default_awc_min_mm_per_m?: number | null
          default_awc_mm_per_m: number
          default_root_depth_m?: number
          description?: string | null
          drainage_risk?: string | null
          infiltration_risk?: string | null
          irrigation_soil_class: string
          label: string
          sort_order?: number
          updated_at?: string
          waterlogging_risk?: string | null
        }
        Update: {
          created_at?: string
          default_allowed_depletion_percent?: number
          default_awc_max_mm_per_m?: number | null
          default_awc_min_mm_per_m?: number | null
          default_awc_mm_per_m?: number
          default_root_depth_m?: number
          description?: string | null
          drainage_risk?: string | null
          infiltration_risk?: string | null
          irrigation_soil_class?: string
          label?: string
          sort_order?: number
          updated_at?: string
          waterlogging_risk?: string | null
        }
        Relationships: []
      }
      soil_sample_block_mappings: {
        Row: {
          created_at: string
          created_by: string | null
          id: string
          mapping_confidence: number | null
          mapping_scope: string
          notes: string | null
          paddock_id: string
          row_end: number | null
          row_ids: string[] | null
          row_numbers: number[] | null
          row_start: number | null
          sample_id: string
          sort_order: number
          updated_at: string
          vineyard_id: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          id?: string
          mapping_confidence?: number | null
          mapping_scope?: string
          notes?: string | null
          paddock_id: string
          row_end?: number | null
          row_ids?: string[] | null
          row_numbers?: number[] | null
          row_start?: number | null
          sample_id: string
          sort_order?: number
          updated_at?: string
          vineyard_id: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          id?: string
          mapping_confidence?: number | null
          mapping_scope?: string
          notes?: string | null
          paddock_id?: string
          row_end?: number | null
          row_ids?: string[] | null
          row_numbers?: number[] | null
          row_start?: number | null
          sample_id?: string
          sort_order?: number
          updated_at?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "soil_sample_block_mappings_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "soil_sample_block_mappings_paddock_id_fkey"
            columns: ["paddock_id"]
            isOneToOne: false
            referencedRelation: "paddocks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "soil_sample_block_mappings_sample_id_fkey"
            columns: ["sample_id"]
            isOneToOne: false
            referencedRelation: "soil_samples"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "soil_sample_block_mappings_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      soil_sample_documents: {
        Row: {
          created_at: string
          extraction_error: string | null
          extraction_model: string | null
          extraction_status: string
          id: string
          is_primary: boolean
          mime_type: string
          original_filename: string
          parser_version: string | null
          raw_extraction: Json | null
          sample_id: string
          sha256: string | null
          size_bytes: number | null
          source_page_count: number | null
          storage_bucket: string
          storage_path: string
          updated_at: string
          uploaded_by: string | null
          vineyard_id: string
        }
        Insert: {
          created_at?: string
          extraction_error?: string | null
          extraction_model?: string | null
          extraction_status?: string
          id?: string
          is_primary?: boolean
          mime_type: string
          original_filename: string
          parser_version?: string | null
          raw_extraction?: Json | null
          sample_id: string
          sha256?: string | null
          size_bytes?: number | null
          source_page_count?: number | null
          storage_bucket?: string
          storage_path: string
          updated_at?: string
          uploaded_by?: string | null
          vineyard_id: string
        }
        Update: {
          created_at?: string
          extraction_error?: string | null
          extraction_model?: string | null
          extraction_status?: string
          id?: string
          is_primary?: boolean
          mime_type?: string
          original_filename?: string
          parser_version?: string | null
          raw_extraction?: Json | null
          sample_id?: string
          sha256?: string | null
          size_bytes?: number | null
          source_page_count?: number | null
          storage_bucket?: string
          storage_path?: string
          updated_at?: string
          uploaded_by?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "soil_sample_documents_sample_id_fkey"
            columns: ["sample_id"]
            isOneToOne: false
            referencedRelation: "soil_samples"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "soil_sample_documents_uploaded_by_fkey"
            columns: ["uploaded_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "soil_sample_documents_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      soil_sample_results: {
        Row: {
          analyte_key: string | null
          created_at: string
          desired_value_numeric: number | null
          display_name: string
          extraction_confidence: number | null
          id: string
          is_user_corrected: boolean
          is_user_verified: boolean
          lab_range_max: number | null
          lab_range_min: number | null
          lab_range_text: string | null
          lab_status: string | null
          method: string | null
          notes: string | null
          original_analyte_name: string
          sample_id: string
          sort_order: number
          source_page: number | null
          source_section: string | null
          source_value_numeric: number | null
          source_value_text: string | null
          unit: string | null
          updated_at: string
          value_numeric: number | null
          value_text: string | null
        }
        Insert: {
          analyte_key?: string | null
          created_at?: string
          desired_value_numeric?: number | null
          display_name: string
          extraction_confidence?: number | null
          id?: string
          is_user_corrected?: boolean
          is_user_verified?: boolean
          lab_range_max?: number | null
          lab_range_min?: number | null
          lab_range_text?: string | null
          lab_status?: string | null
          method?: string | null
          notes?: string | null
          original_analyte_name: string
          sample_id: string
          sort_order?: number
          source_page?: number | null
          source_section?: string | null
          source_value_numeric?: number | null
          source_value_text?: string | null
          unit?: string | null
          updated_at?: string
          value_numeric?: number | null
          value_text?: string | null
        }
        Update: {
          analyte_key?: string | null
          created_at?: string
          desired_value_numeric?: number | null
          display_name?: string
          extraction_confidence?: number | null
          id?: string
          is_user_corrected?: boolean
          is_user_verified?: boolean
          lab_range_max?: number | null
          lab_range_min?: number | null
          lab_range_text?: string | null
          lab_status?: string | null
          method?: string | null
          notes?: string | null
          original_analyte_name?: string
          sample_id?: string
          sort_order?: number
          source_page?: number | null
          source_section?: string | null
          source_value_numeric?: number | null
          source_value_text?: string | null
          unit?: string | null
          updated_at?: string
          value_numeric?: number | null
          value_text?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "soil_sample_results_analyte_key_fkey"
            columns: ["analyte_key"]
            isOneToOne: false
            referencedRelation: "soil_analyte_catalogue"
            referencedColumns: ["key"]
          },
          {
            foreignKeyName: "soil_sample_results_sample_id_fkey"
            columns: ["sample_id"]
            isOneToOne: false
            referencedRelation: "soil_samples"
            referencedColumns: ["id"]
          },
        ]
      }
      soil_samples: {
        Row: {
          client_agronomist: string | null
          created_at: string
          created_by: string | null
          crop: string | null
          deleted_at: string | null
          extraction_confidence: number | null
          extraction_status: string
          id: string
          lab_code: string | null
          lab_paddock_name: string | null
          lab_sample_id: string | null
          laboratory: string | null
          latitude: number | null
          longitude: number | null
          mapping_confidence: number | null
          notes: string | null
          order_number: string | null
          paddock_id: string | null
          received_at: string | null
          reported_at: string | null
          row_end: number | null
          row_start: number | null
          sample_depth_from_cm: number | null
          sample_depth_to_cm: number | null
          sample_scope: string
          sampled_at: string | null
          soil_type: string | null
          updated_at: string
          verified_at: string | null
          verified_by: string | null
          vineyard_id: string
        }
        Insert: {
          client_agronomist?: string | null
          created_at?: string
          created_by?: string | null
          crop?: string | null
          deleted_at?: string | null
          extraction_confidence?: number | null
          extraction_status?: string
          id?: string
          lab_code?: string | null
          lab_paddock_name?: string | null
          lab_sample_id?: string | null
          laboratory?: string | null
          latitude?: number | null
          longitude?: number | null
          mapping_confidence?: number | null
          notes?: string | null
          order_number?: string | null
          paddock_id?: string | null
          received_at?: string | null
          reported_at?: string | null
          row_end?: number | null
          row_start?: number | null
          sample_depth_from_cm?: number | null
          sample_depth_to_cm?: number | null
          sample_scope?: string
          sampled_at?: string | null
          soil_type?: string | null
          updated_at?: string
          verified_at?: string | null
          verified_by?: string | null
          vineyard_id: string
        }
        Update: {
          client_agronomist?: string | null
          created_at?: string
          created_by?: string | null
          crop?: string | null
          deleted_at?: string | null
          extraction_confidence?: number | null
          extraction_status?: string
          id?: string
          lab_code?: string | null
          lab_paddock_name?: string | null
          lab_sample_id?: string | null
          laboratory?: string | null
          latitude?: number | null
          longitude?: number | null
          mapping_confidence?: number | null
          notes?: string | null
          order_number?: string | null
          paddock_id?: string | null
          received_at?: string | null
          reported_at?: string | null
          row_end?: number | null
          row_start?: number | null
          sample_depth_from_cm?: number | null
          sample_depth_to_cm?: number | null
          sample_scope?: string
          sampled_at?: string | null
          soil_type?: string | null
          updated_at?: string
          verified_at?: string | null
          verified_by?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "soil_samples_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "soil_samples_paddock_id_fkey"
            columns: ["paddock_id"]
            isOneToOne: false
            referencedRelation: "paddocks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "soil_samples_verified_by_fkey"
            columns: ["verified_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "soil_samples_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      spray_equipment: {
        Row: {
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          name: string
          serial_number: string | null
          sync_version: number
          tank_capacity_litres: number
          updated_at: string
          updated_by: string | null
          vin_number: string | null
          vineyard_id: string
        }
        Insert: {
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          name?: string
          serial_number?: string | null
          sync_version?: number
          tank_capacity_litres?: number
          updated_at?: string
          updated_by?: string | null
          vin_number?: string | null
          vineyard_id: string
        }
        Update: {
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          name?: string
          serial_number?: string | null
          sync_version?: number
          tank_capacity_litres?: number
          updated_at?: string
          updated_by?: string | null
          vin_number?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "spray_equipment_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      spray_job_paddocks: {
        Row: {
          created_at: string
          paddock_id: string
          spray_job_id: string
        }
        Insert: {
          created_at?: string
          paddock_id: string
          spray_job_id: string
        }
        Update: {
          created_at?: string
          paddock_id?: string
          spray_job_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "spray_job_paddocks_paddock_id_fkey"
            columns: ["paddock_id"]
            isOneToOne: false
            referencedRelation: "paddocks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "spray_job_paddocks_spray_job_id_fkey"
            columns: ["spray_job_id"]
            isOneToOne: false
            referencedRelation: "spray_jobs"
            referencedColumns: ["id"]
          },
        ]
      }
      spray_jobs: {
        Row: {
          application_mode: string | null
          applied_litres_per_100m: number | null
          band_width_left_metres: number | null
          band_width_right_metres: number | null
          band_width_total_metres: number | null
          canonical_row_length_metres: number | null
          carrier_area_basis: string | null
          carrier_volume_basis: string | null
          chemical_lines: Json | null
          concentration_factor: number | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          dilute_litres_per_100m: number | null
          equipment_id: string | null
          geometry_quality: string | null
          geometry_source: string | null
          gross_area_ha: number | null
          ground_application_target: string | null
          growth_stage_code: string | null
          id: string
          is_template: boolean
          name: string
          notes: string | null
          operation_type: string | null
          operator_user_id: string | null
          planned_date: string | null
          resistance_plan_id: string | null
          resistance_plan_source_revision: number | null
          resistance_position_id: string | null
          resistance_position_snapshot: Json | null
          row_spacing_metres: number | null
          spray_head_target: string | null
          spray_rate_per_ha: number | null
          status: string
          target: string | null
          targets: string[] | null
          tractor_id: string | null
          treated_area_ha: number | null
          treated_area_method: string | null
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          vsp_canopy_density: string | null
          vsp_canopy_size: string | null
          water_volume: number | null
        }
        Insert: {
          application_mode?: string | null
          applied_litres_per_100m?: number | null
          band_width_left_metres?: number | null
          band_width_right_metres?: number | null
          band_width_total_metres?: number | null
          canonical_row_length_metres?: number | null
          carrier_area_basis?: string | null
          carrier_volume_basis?: string | null
          chemical_lines?: Json | null
          concentration_factor?: number | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          dilute_litres_per_100m?: number | null
          equipment_id?: string | null
          geometry_quality?: string | null
          geometry_source?: string | null
          gross_area_ha?: number | null
          ground_application_target?: string | null
          growth_stage_code?: string | null
          id?: string
          is_template?: boolean
          name?: string
          notes?: string | null
          operation_type?: string | null
          operator_user_id?: string | null
          planned_date?: string | null
          resistance_plan_id?: string | null
          resistance_plan_source_revision?: number | null
          resistance_position_id?: string | null
          resistance_position_snapshot?: Json | null
          row_spacing_metres?: number | null
          spray_head_target?: string | null
          spray_rate_per_ha?: number | null
          status?: string
          target?: string | null
          targets?: string[] | null
          tractor_id?: string | null
          treated_area_ha?: number | null
          treated_area_method?: string | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
          vsp_canopy_density?: string | null
          vsp_canopy_size?: string | null
          water_volume?: number | null
        }
        Update: {
          application_mode?: string | null
          applied_litres_per_100m?: number | null
          band_width_left_metres?: number | null
          band_width_right_metres?: number | null
          band_width_total_metres?: number | null
          canonical_row_length_metres?: number | null
          carrier_area_basis?: string | null
          carrier_volume_basis?: string | null
          chemical_lines?: Json | null
          concentration_factor?: number | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          dilute_litres_per_100m?: number | null
          equipment_id?: string | null
          geometry_quality?: string | null
          geometry_source?: string | null
          gross_area_ha?: number | null
          ground_application_target?: string | null
          growth_stage_code?: string | null
          id?: string
          is_template?: boolean
          name?: string
          notes?: string | null
          operation_type?: string | null
          operator_user_id?: string | null
          planned_date?: string | null
          resistance_plan_id?: string | null
          resistance_plan_source_revision?: number | null
          resistance_position_id?: string | null
          resistance_position_snapshot?: Json | null
          row_spacing_metres?: number | null
          spray_head_target?: string | null
          spray_rate_per_ha?: number | null
          status?: string
          target?: string | null
          targets?: string[] | null
          tractor_id?: string | null
          treated_area_ha?: number | null
          treated_area_method?: string | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
          vsp_canopy_density?: string | null
          vsp_canopy_size?: string | null
          water_volume?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "spray_jobs_equipment_id_fkey"
            columns: ["equipment_id"]
            isOneToOne: false
            referencedRelation: "spray_equipment"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "spray_jobs_tractor_id_fkey"
            columns: ["tractor_id"]
            isOneToOne: false
            referencedRelation: "tractors"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "spray_jobs_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      spray_records: {
        Row: {
          application_blocks: Json | null
          application_mode: string | null
          applied_litres_per_100m: number | null
          average_speed: number | null
          band_width_left_metres: number | null
          band_width_right_metres: number | null
          band_width_total_metres: number | null
          block_ids: string[] | null
          canonical_row_length_metres: number | null
          carrier_area_basis: string | null
          carrier_litres_per_hectare: number | null
          carrier_volume_basis: string | null
          client_updated_at: string | null
          concentration_factor: number | null
          created_at: string
          created_by: string | null
          date: string | null
          deleted_at: string | null
          dilute_litres_per_100m: number | null
          end_time: string | null
          entry_source: string | null
          equipment_type: string | null
          geometry_quality: string | null
          geometry_source: string | null
          gross_area_ha: number | null
          ground_application_target: string | null
          humidity: number | null
          id: string
          is_template: boolean
          machine_id: string | null
          manual_entry_id: string | null
          notes: string | null
          number_of_fans_jets: string | null
          operation_type: string | null
          row_spacing_metres: number | null
          spray_equipment_id: string | null
          spray_head_target: string | null
          spray_job_id: string | null
          spray_reference: string | null
          start_time: string | null
          sync_version: number
          tanks: Json | null
          targets: string[] | null
          temperature: number | null
          total_carrier_litres: number | null
          tractor: string | null
          tractor_gear: string | null
          tractor_id: string | null
          treated_area_ha: number | null
          treated_area_method: string | null
          trip_id: string | null
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          wind_direction: string | null
          wind_speed: number | null
        }
        Insert: {
          application_blocks?: Json | null
          application_mode?: string | null
          applied_litres_per_100m?: number | null
          average_speed?: number | null
          band_width_left_metres?: number | null
          band_width_right_metres?: number | null
          band_width_total_metres?: number | null
          block_ids?: string[] | null
          canonical_row_length_metres?: number | null
          carrier_area_basis?: string | null
          carrier_litres_per_hectare?: number | null
          carrier_volume_basis?: string | null
          client_updated_at?: string | null
          concentration_factor?: number | null
          created_at?: string
          created_by?: string | null
          date?: string | null
          deleted_at?: string | null
          dilute_litres_per_100m?: number | null
          end_time?: string | null
          entry_source?: string | null
          equipment_type?: string | null
          geometry_quality?: string | null
          geometry_source?: string | null
          gross_area_ha?: number | null
          ground_application_target?: string | null
          humidity?: number | null
          id?: string
          is_template?: boolean
          machine_id?: string | null
          manual_entry_id?: string | null
          notes?: string | null
          number_of_fans_jets?: string | null
          operation_type?: string | null
          row_spacing_metres?: number | null
          spray_equipment_id?: string | null
          spray_head_target?: string | null
          spray_job_id?: string | null
          spray_reference?: string | null
          start_time?: string | null
          sync_version?: number
          tanks?: Json | null
          targets?: string[] | null
          temperature?: number | null
          total_carrier_litres?: number | null
          tractor?: string | null
          tractor_gear?: string | null
          tractor_id?: string | null
          treated_area_ha?: number | null
          treated_area_method?: string | null
          trip_id?: string | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
          wind_direction?: string | null
          wind_speed?: number | null
        }
        Update: {
          application_blocks?: Json | null
          application_mode?: string | null
          applied_litres_per_100m?: number | null
          average_speed?: number | null
          band_width_left_metres?: number | null
          band_width_right_metres?: number | null
          band_width_total_metres?: number | null
          block_ids?: string[] | null
          canonical_row_length_metres?: number | null
          carrier_area_basis?: string | null
          carrier_litres_per_hectare?: number | null
          carrier_volume_basis?: string | null
          client_updated_at?: string | null
          concentration_factor?: number | null
          created_at?: string
          created_by?: string | null
          date?: string | null
          deleted_at?: string | null
          dilute_litres_per_100m?: number | null
          end_time?: string | null
          entry_source?: string | null
          equipment_type?: string | null
          geometry_quality?: string | null
          geometry_source?: string | null
          gross_area_ha?: number | null
          ground_application_target?: string | null
          humidity?: number | null
          id?: string
          is_template?: boolean
          machine_id?: string | null
          manual_entry_id?: string | null
          notes?: string | null
          number_of_fans_jets?: string | null
          operation_type?: string | null
          row_spacing_metres?: number | null
          spray_equipment_id?: string | null
          spray_head_target?: string | null
          spray_job_id?: string | null
          spray_reference?: string | null
          start_time?: string | null
          sync_version?: number
          tanks?: Json | null
          targets?: string[] | null
          temperature?: number | null
          total_carrier_litres?: number | null
          tractor?: string | null
          tractor_gear?: string | null
          tractor_id?: string | null
          treated_area_ha?: number | null
          treated_area_method?: string | null
          trip_id?: string | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
          wind_direction?: string | null
          wind_speed?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "spray_records_spray_job_id_fkey"
            columns: ["spray_job_id"]
            isOneToOne: false
            referencedRelation: "spray_jobs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "spray_records_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      spray_row_assignment_evidence: {
        Row: {
          assignment_source: string
          block_id: string
          block_name_snapshot: string
          confidence: number
          derived_at: string
          derived_by: string
          id: string
          operation_id: string
          original_evidence: Json
          row_identity: string
          row_number: number
          status: string
          tank_number: number | null
          tank_session_id: string
          trip_id: string
          vineyard_id: string
        }
        Insert: {
          assignment_source: string
          block_id: string
          block_name_snapshot: string
          confidence: number
          derived_at?: string
          derived_by: string
          id?: string
          operation_id: string
          original_evidence: Json
          row_identity: string
          row_number: number
          status: string
          tank_number?: number | null
          tank_session_id?: string
          trip_id: string
          vineyard_id: string
        }
        Update: {
          assignment_source?: string
          block_id?: string
          block_name_snapshot?: string
          confidence?: number
          derived_at?: string
          derived_by?: string
          id?: string
          operation_id?: string
          original_evidence?: Json
          row_identity?: string
          row_number?: number
          status?: string
          tank_number?: number | null
          tank_session_id?: string
          trip_id?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "spray_row_assignment_evidence_trip_id_fkey"
            columns: ["trip_id"]
            isOneToOne: false
            referencedRelation: "trips"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "spray_row_assignment_evidence_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      spray_row_recovery_operations: {
        Row: {
          actor_user_id: string
          assignment_count: number
          assignment_fingerprint: string
          completed_at: string
          operation_id: string
          trip_id: string
          vineyard_id: string
        }
        Insert: {
          actor_user_id: string
          assignment_count: number
          assignment_fingerprint: string
          completed_at?: string
          operation_id: string
          trip_id: string
          vineyard_id: string
        }
        Update: {
          actor_user_id?: string
          assignment_count?: number
          assignment_fingerprint?: string
          completed_at?: string
          operation_id?: string
          trip_id?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "spray_row_recovery_operations_trip_id_fkey"
            columns: ["trip_id"]
            isOneToOne: false
            referencedRelation: "trips"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "spray_row_recovery_operations_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      spray_row_recovery_trip_guard: {
        Row: {
          accepted_count: number
          last_started_at: string
          trip_id: string
          window_started_at: string
        }
        Insert: {
          accepted_count: number
          last_started_at: string
          trip_id: string
          window_started_at: string
        }
        Update: {
          accepted_count?: number
          last_started_at?: string
          trip_id?: string
          window_started_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "spray_row_recovery_trip_guard_trip_id_fkey"
            columns: ["trip_id"]
            isOneToOne: true
            referencedRelation: "trips"
            referencedColumns: ["id"]
          },
        ]
      }
      spray_tank_actual_amendments: {
        Row: {
          change_kind: string
          chemical_actual_id: string | null
          edited_at: string
          edited_by: string
          editor_name: string
          field_name: string
          id: string
          new_unit: string | null
          new_value: Json | null
          operation_id: string
          planned_chemical_id: string | null
          previous_unit: string | null
          previous_value: Json | null
          revision: number
          saved_chemical_id: string | null
          spray_record_id: string
          spray_tank_actual_id: string
          tank_number: number
          trip_id: string
          vineyard_id: string
        }
        Insert: {
          change_kind: string
          chemical_actual_id?: string | null
          edited_at?: string
          edited_by: string
          editor_name: string
          field_name: string
          id?: string
          new_unit?: string | null
          new_value?: Json | null
          operation_id: string
          planned_chemical_id?: string | null
          previous_unit?: string | null
          previous_value?: Json | null
          revision: number
          saved_chemical_id?: string | null
          spray_record_id: string
          spray_tank_actual_id: string
          tank_number: number
          trip_id: string
          vineyard_id: string
        }
        Update: {
          change_kind?: string
          chemical_actual_id?: string | null
          edited_at?: string
          edited_by?: string
          editor_name?: string
          field_name?: string
          id?: string
          new_unit?: string | null
          new_value?: Json | null
          operation_id?: string
          planned_chemical_id?: string | null
          previous_unit?: string | null
          previous_value?: Json | null
          revision?: number
          saved_chemical_id?: string | null
          spray_record_id?: string
          spray_tank_actual_id?: string
          tank_number?: number
          trip_id?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "spray_tank_actual_amendments_spray_record_id_fkey"
            columns: ["spray_record_id"]
            isOneToOne: false
            referencedRelation: "spray_records"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "spray_tank_actual_amendments_spray_tank_actual_id_fkey"
            columns: ["spray_tank_actual_id"]
            isOneToOne: false
            referencedRelation: "spray_tank_actuals"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "spray_tank_actual_amendments_trip_id_fkey"
            columns: ["trip_id"]
            isOneToOne: false
            referencedRelation: "trips"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "spray_tank_actual_amendments_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      spray_tank_actuals: {
        Row: {
          chemicals: Json
          client_updated_at: string
          confirmed_at: string
          confirmed_by: string
          correction_version: number
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          last_corrected_at: string | null
          spray_record_id: string
          sync_version: number
          tank_number: number
          tank_session_id: string
          trip_id: string
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          water_volume_l: number | null
        }
        Insert: {
          chemicals?: Json
          client_updated_at: string
          confirmed_at: string
          confirmed_by: string
          correction_version?: number
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id: string
          last_corrected_at?: string | null
          spray_record_id: string
          sync_version?: number
          tank_number: number
          tank_session_id: string
          trip_id: string
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
          water_volume_l?: number | null
        }
        Update: {
          chemicals?: Json
          client_updated_at?: string
          confirmed_at?: string
          confirmed_by?: string
          correction_version?: number
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          last_corrected_at?: string | null
          spray_record_id?: string
          sync_version?: number
          tank_number?: number
          tank_session_id?: string
          trip_id?: string
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
          water_volume_l?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "spray_tank_actuals_spray_record_id_fkey"
            columns: ["spray_record_id"]
            isOneToOne: false
            referencedRelation: "spray_records"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "spray_tank_actuals_trip_id_fkey"
            columns: ["trip_id"]
            isOneToOne: false
            referencedRelation: "trips"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "spray_tank_actuals_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      spray_trip_correction_amendments: {
        Row: {
          edited_at: string
          edited_by: string
          editor_name: string
          id: string
          new_value: Json
          operation_id: string
          previous_value: Json
          revision: number
          trip_id: string
          vineyard_id: string
        }
        Insert: {
          edited_at?: string
          edited_by: string
          editor_name: string
          id?: string
          new_value: Json
          operation_id: string
          previous_value: Json
          revision: number
          trip_id: string
          vineyard_id: string
        }
        Update: {
          edited_at?: string
          edited_by?: string
          editor_name?: string
          id?: string
          new_value?: Json
          operation_id?: string
          previous_value?: Json
          revision?: number
          trip_id?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "spray_trip_correction_amendments_trip_id_fkey"
            columns: ["trip_id"]
            isOneToOne: false
            referencedRelation: "trips"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "spray_trip_correction_amendments_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      spray_trip_correction_operations: {
        Row: {
          completed_at: string
          operation_id: string
          request_fingerprint: string
          result_version: number
          trip_id: string
          vineyard_id: string
        }
        Insert: {
          completed_at?: string
          operation_id: string
          request_fingerprint: string
          result_version: number
          trip_id: string
          vineyard_id: string
        }
        Update: {
          completed_at?: string
          operation_id?: string
          request_fingerprint?: string
          result_version?: number
          trip_id?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "spray_trip_correction_operations_trip_id_fkey"
            columns: ["trip_id"]
            isOneToOne: false
            referencedRelation: "trips"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "spray_trip_correction_operations_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      spray_trip_corrections: {
        Row: {
          corrected_at: string
          corrected_by: string
          end_engine_hours: number | null
          fuel_consumption_l_per_hour: number | null
          fuel_consumption_source: string | null
          machine_id: string | null
          machine_name_snapshot: string | null
          operator_name_snapshot: string | null
          operator_user_id: string | null
          spray_equipment_id: string | null
          spray_unit_name_snapshot: string | null
          start_engine_hours: number | null
          tractor_id: string | null
          trip_id: string
          version: number
          vineyard_id: string
        }
        Insert: {
          corrected_at?: string
          corrected_by: string
          end_engine_hours?: number | null
          fuel_consumption_l_per_hour?: number | null
          fuel_consumption_source?: string | null
          machine_id?: string | null
          machine_name_snapshot?: string | null
          operator_name_snapshot?: string | null
          operator_user_id?: string | null
          spray_equipment_id?: string | null
          spray_unit_name_snapshot?: string | null
          start_engine_hours?: number | null
          tractor_id?: string | null
          trip_id: string
          version?: number
          vineyard_id: string
        }
        Update: {
          corrected_at?: string
          corrected_by?: string
          end_engine_hours?: number | null
          fuel_consumption_l_per_hour?: number | null
          fuel_consumption_source?: string | null
          machine_id?: string | null
          machine_name_snapshot?: string | null
          operator_name_snapshot?: string | null
          operator_user_id?: string | null
          spray_equipment_id?: string | null
          spray_unit_name_snapshot?: string | null
          start_engine_hours?: number | null
          tractor_id?: string | null
          trip_id?: string
          version?: number
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "spray_trip_corrections_machine_id_fkey"
            columns: ["machine_id"]
            isOneToOne: false
            referencedRelation: "vineyard_machines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "spray_trip_corrections_spray_equipment_id_fkey"
            columns: ["spray_equipment_id"]
            isOneToOne: false
            referencedRelation: "spray_equipment"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "spray_trip_corrections_tractor_id_fkey"
            columns: ["tractor_id"]
            isOneToOne: false
            referencedRelation: "tractors"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "spray_trip_corrections_trip_id_fkey"
            columns: ["trip_id"]
            isOneToOne: true
            referencedRelation: "trips"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "spray_trip_corrections_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      support_requests: {
        Row: {
          app_build: string | null
          app_platform: string | null
          app_version: string | null
          attachment_count: number
          attachment_paths: string[]
          category: string
          created_at: string
          device_model: string | null
          email_error: string | null
          email_provider_id: string | null
          email_sent_at: string | null
          email_status: string
          id: string
          message: string
          os_version: string | null
          status: string
          subject: string
          submitter_email: string | null
          submitter_name: string | null
          user_id: string | null
          vineyard_id: string | null
          vineyard_name: string | null
        }
        Insert: {
          app_build?: string | null
          app_platform?: string | null
          app_version?: string | null
          attachment_count?: number
          attachment_paths?: string[]
          category?: string
          created_at?: string
          device_model?: string | null
          email_error?: string | null
          email_provider_id?: string | null
          email_sent_at?: string | null
          email_status?: string
          id?: string
          message: string
          os_version?: string | null
          status?: string
          subject: string
          submitter_email?: string | null
          submitter_name?: string | null
          user_id?: string | null
          vineyard_id?: string | null
          vineyard_name?: string | null
        }
        Update: {
          app_build?: string | null
          app_platform?: string | null
          app_version?: string | null
          attachment_count?: number
          attachment_paths?: string[]
          category?: string
          created_at?: string
          device_model?: string | null
          email_error?: string | null
          email_provider_id?: string | null
          email_sent_at?: string | null
          email_status?: string
          id?: string
          message?: string
          os_version?: string | null
          status?: string
          subject?: string
          submitter_email?: string | null
          submitter_name?: string | null
          user_id?: string | null
          vineyard_id?: string | null
          vineyard_name?: string | null
        }
        Relationships: []
      }
      sync_discarded_writes: {
        Row: {
          attempted_at: string
          attempted_by: string | null
          attempted_client_updated_at: string | null
          attempted_payload: Json
          id: number
          reason: string
          row_id: string | null
          stored_client_updated_at: string | null
          stored_server_revision: number | null
          table_name: string
          vineyard_id: string | null
        }
        Insert: {
          attempted_at?: string
          attempted_by?: string | null
          attempted_client_updated_at?: string | null
          attempted_payload: Json
          id?: number
          reason: string
          row_id?: string | null
          stored_client_updated_at?: string | null
          stored_server_revision?: number | null
          table_name: string
          vineyard_id?: string | null
        }
        Update: {
          attempted_at?: string
          attempted_by?: string | null
          attempted_client_updated_at?: string | null
          attempted_payload?: Json
          id?: number
          reason?: string
          row_id?: string | null
          stored_client_updated_at?: string | null
          stored_server_revision?: number | null
          table_name?: string
          vineyard_id?: string | null
        }
        Relationships: []
      }
      system_admins: {
        Row: {
          created_at: string
          created_by: string | null
          email: string | null
          is_active: boolean
          user_id: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          email?: string | null
          is_active?: boolean
          user_id: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          email?: string | null
          is_active?: boolean
          user_id?: string
        }
        Relationships: []
      }
      system_feature_flags: {
        Row: {
          category: string | null
          created_at: string
          description: string | null
          id: string
          is_enabled: boolean
          key: string
          label: string | null
          updated_at: string
          updated_by: string | null
          value: Json
          value_type: string
        }
        Insert: {
          category?: string | null
          created_at?: string
          description?: string | null
          id?: string
          is_enabled?: boolean
          key: string
          label?: string | null
          updated_at?: string
          updated_by?: string | null
          value?: Json
          value_type?: string
        }
        Update: {
          category?: string | null
          created_at?: string
          description?: string | null
          id?: string
          is_enabled?: boolean
          key?: string
          label?: string | null
          updated_at?: string
          updated_by?: string | null
          value?: Json
          value_type?: string
        }
        Relationships: []
      }
      tractor_fuel_logs: {
        Row: {
          client_updated_at: string | null
          cost_per_litre: number | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          engine_hours: number | null
          external_id: string | null
          fill_datetime: string
          filled_to_full: boolean | null
          id: string
          integration_api_key_id: string | null
          integration_client_id: string | null
          litres_added: number
          machine_id: string | null
          notes: string | null
          operator_name: string | null
          operator_user_id: string | null
          origin: string
          sync_version: number
          total_cost: number | null
          tractor_id: string | null
          updated_at: string
          updated_by: string | null
          updated_by_integration_client_id: string | null
          vineyard_id: string
        }
        Insert: {
          client_updated_at?: string | null
          cost_per_litre?: number | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          engine_hours?: number | null
          external_id?: string | null
          fill_datetime?: string
          filled_to_full?: boolean | null
          id?: string
          integration_api_key_id?: string | null
          integration_client_id?: string | null
          litres_added?: number
          machine_id?: string | null
          notes?: string | null
          operator_name?: string | null
          operator_user_id?: string | null
          origin?: string
          sync_version?: number
          total_cost?: number | null
          tractor_id?: string | null
          updated_at?: string
          updated_by?: string | null
          updated_by_integration_client_id?: string | null
          vineyard_id: string
        }
        Update: {
          client_updated_at?: string | null
          cost_per_litre?: number | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          engine_hours?: number | null
          external_id?: string | null
          fill_datetime?: string
          filled_to_full?: boolean | null
          id?: string
          integration_api_key_id?: string | null
          integration_client_id?: string | null
          litres_added?: number
          machine_id?: string | null
          notes?: string | null
          operator_name?: string | null
          operator_user_id?: string | null
          origin?: string
          sync_version?: number
          total_cost?: number | null
          tractor_id?: string | null
          updated_at?: string
          updated_by?: string | null
          updated_by_integration_client_id?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "tractor_fuel_logs_integration_api_key_id_fkey"
            columns: ["integration_api_key_id"]
            isOneToOne: false
            referencedRelation: "integration_api_keys"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tractor_fuel_logs_integration_client_id_fkey"
            columns: ["integration_client_id"]
            isOneToOne: false
            referencedRelation: "integration_clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tractor_fuel_logs_machine_id_fkey"
            columns: ["machine_id"]
            isOneToOne: false
            referencedRelation: "vineyard_machines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tractor_fuel_logs_tractor_id_fkey"
            columns: ["tractor_id"]
            isOneToOne: false
            referencedRelation: "tractors"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tractor_fuel_logs_updated_by_integration_client_id_fkey"
            columns: ["updated_by_integration_client_id"]
            isOneToOne: false
            referencedRelation: "integration_clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tractor_fuel_logs_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      tractor_photos: {
        Row: {
          byte_size: number | null
          content_type: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          storage_path: string
          tractor_id: string
          updated_at: string
          vineyard_id: string
        }
        Insert: {
          byte_size?: number | null
          content_type: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          storage_path: string
          tractor_id: string
          updated_at?: string
          vineyard_id: string
        }
        Update: {
          byte_size?: number | null
          content_type?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          storage_path?: string
          tractor_id?: string
          updated_at?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "tractor_photos_tractor_id_fkey"
            columns: ["tractor_id"]
            isOneToOne: false
            referencedRelation: "tractors"
            referencedColumns: ["id"]
          },
        ]
      }
      tractors: {
        Row: {
          brand: string
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          fuel_usage_l_per_hour: number
          id: string
          model: string
          model_year: number | null
          name: string
          serial_number: string | null
          sync_version: number
          updated_at: string
          updated_by: string | null
          vin_number: string | null
          vineyard_id: string
        }
        Insert: {
          brand?: string
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          fuel_usage_l_per_hour?: number
          id?: string
          model?: string
          model_year?: number | null
          name?: string
          serial_number?: string | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vin_number?: string | null
          vineyard_id: string
        }
        Update: {
          brand?: string
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          fuel_usage_l_per_hour?: number
          id?: string
          model?: string
          model_year?: number | null
          name?: string
          serial_number?: string | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vin_number?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "tractors_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      trip_activity_cancellation_receipts: {
        Row: {
          actor_role: string
          actor_user_id: string
          application_classification: string
          cancelled_at: string
          client_baseline: Json
          compliance_archive_id: string | null
          operation_id: string
          removed_counts: Json
          server_revision: number
          spray_record_ids: string[]
          status: string
          trip_id: string
          vineyard_id: string
        }
        Insert: {
          actor_role: string
          actor_user_id: string
          application_classification: string
          cancelled_at?: string
          client_baseline?: Json
          compliance_archive_id?: string | null
          operation_id: string
          removed_counts: Json
          server_revision?: never
          spray_record_ids?: string[]
          status?: string
          trip_id: string
          vineyard_id: string
        }
        Update: {
          actor_role?: string
          actor_user_id?: string
          application_classification?: string
          cancelled_at?: string
          client_baseline?: Json
          compliance_archive_id?: string | null
          operation_id?: string
          removed_counts?: Json
          server_revision?: never
          spray_record_ids?: string[]
          status?: string
          trip_id?: string
          vineyard_id?: string
        }
        Relationships: []
      }
      trip_compliance_archive: {
        Row: {
          created_at: string
          created_by: string
          facts: Json
          id: string
          operation_id: string
          retain_until: string
          source: string
          trip_id: string
          vineyard_id: string
        }
        Insert: {
          created_at?: string
          created_by: string
          facts: Json
          id?: string
          operation_id: string
          retain_until: string
          source: string
          trip_id: string
          vineyard_id: string
        }
        Update: {
          created_at?: string
          created_by?: string
          facts?: Json
          id?: string
          operation_id?: string
          retain_until?: string
          source?: string
          trip_id?: string
          vineyard_id?: string
        }
        Relationships: []
      }
      trip_cost_allocations: {
        Row: {
          allocation_area_ha: number | null
          allocation_basis: string
          calculated_at: string
          chemical_cost: number | null
          client_updated_at: string | null
          cost_per_ha: number | null
          cost_per_tonne: number | null
          costing_status: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          fuel_cost: number | null
          hourly_rate_snapshot: number | null
          id: string
          input_cost: number | null
          labour_cost: number | null
          labour_hours: number | null
          paddock_id: string | null
          paddock_name: string | null
          rate_captured_at: string | null
          season_year: number
          source_trip_updated_at: string | null
          sync_version: number
          total_cost: number | null
          trip_function: string | null
          trip_id: string
          updated_at: string
          updated_by: string | null
          variety: string | null
          variety_id: string | null
          variety_percentage: number | null
          vineyard_id: string
          warnings: string[] | null
          worker_type_id: string | null
          worker_type_name_snapshot: string | null
          worker_user_id: string | null
          yield_tonnes: number | null
        }
        Insert: {
          allocation_area_ha?: number | null
          allocation_basis?: string
          calculated_at?: string
          chemical_cost?: number | null
          client_updated_at?: string | null
          cost_per_ha?: number | null
          cost_per_tonne?: number | null
          costing_status?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          fuel_cost?: number | null
          hourly_rate_snapshot?: number | null
          id?: string
          input_cost?: number | null
          labour_cost?: number | null
          labour_hours?: number | null
          paddock_id?: string | null
          paddock_name?: string | null
          rate_captured_at?: string | null
          season_year: number
          source_trip_updated_at?: string | null
          sync_version?: number
          total_cost?: number | null
          trip_function?: string | null
          trip_id: string
          updated_at?: string
          updated_by?: string | null
          variety?: string | null
          variety_id?: string | null
          variety_percentage?: number | null
          vineyard_id: string
          warnings?: string[] | null
          worker_type_id?: string | null
          worker_type_name_snapshot?: string | null
          worker_user_id?: string | null
          yield_tonnes?: number | null
        }
        Update: {
          allocation_area_ha?: number | null
          allocation_basis?: string
          calculated_at?: string
          chemical_cost?: number | null
          client_updated_at?: string | null
          cost_per_ha?: number | null
          cost_per_tonne?: number | null
          costing_status?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          fuel_cost?: number | null
          hourly_rate_snapshot?: number | null
          id?: string
          input_cost?: number | null
          labour_cost?: number | null
          labour_hours?: number | null
          paddock_id?: string | null
          paddock_name?: string | null
          rate_captured_at?: string | null
          season_year?: number
          source_trip_updated_at?: string | null
          sync_version?: number
          total_cost?: number | null
          trip_function?: string | null
          trip_id?: string
          updated_at?: string
          updated_by?: string | null
          variety?: string | null
          variety_id?: string | null
          variety_percentage?: number | null
          vineyard_id?: string
          warnings?: string[] | null
          worker_type_id?: string | null
          worker_type_name_snapshot?: string | null
          worker_user_id?: string | null
          yield_tonnes?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "trip_cost_allocations_paddock_id_fkey"
            columns: ["paddock_id"]
            isOneToOne: false
            referencedRelation: "paddocks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "trip_cost_allocations_trip_id_fkey"
            columns: ["trip_id"]
            isOneToOne: false
            referencedRelation: "trips"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "trip_cost_allocations_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      trip_occurrence_operations: {
        Row: {
          accepted_at: string
          actor_id: string
          occurrence_id: string | null
          operation_id: string
          previous_state: Json | null
          request: Json
          result: Json
          resulting_state: Json | null
          trip_id: string
          vineyard_id: string
        }
        Insert: {
          accepted_at?: string
          actor_id: string
          occurrence_id?: string | null
          operation_id: string
          previous_state?: Json | null
          request: Json
          result: Json
          resulting_state?: Json | null
          trip_id: string
          vineyard_id: string
        }
        Update: {
          accepted_at?: string
          actor_id?: string
          occurrence_id?: string | null
          operation_id?: string
          previous_state?: Json | null
          request?: Json
          result?: Json
          resulting_state?: Json | null
          trip_id?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "trip_occurrence_operations_trip_id_fkey"
            columns: ["trip_id"]
            isOneToOne: false
            referencedRelation: "trips"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "trip_occurrence_operations_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      trip_report_assets: {
        Row: {
          asset_kind: string
          bucket: string
          created_at: string
          created_by: string | null
          id: string
          object_path: string
          route_hash: string
          sha256: string
          style_version: string
          trip_id: string
          vineyard_id: string
        }
        Insert: {
          asset_kind?: string
          bucket?: string
          created_at?: string
          created_by?: string | null
          id?: string
          object_path: string
          route_hash: string
          sha256: string
          style_version?: string
          trip_id: string
          vineyard_id: string
        }
        Update: {
          asset_kind?: string
          bucket?: string
          created_at?: string
          created_by?: string | null
          id?: string
          object_path?: string
          route_hash?: string
          sha256?: string
          style_version?: string
          trip_id?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "trip_report_assets_trip_id_fkey"
            columns: ["trip_id"]
            isOneToOne: false
            referencedRelation: "trips"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "trip_report_assets_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      trip_weather_observations: {
        Row: {
          captured_at: string
          humidity_pct: number | null
          id: string
          is_stale: boolean
          observed_at: string | null
          provider: string | null
          provider_record_id: string | null
          rain_mm: number | null
          retrieval_mode: string
          retrieved_at: string
          sample_slot: string
          source: string
          source_kind: string
          station_id: string | null
          station_name: string | null
          temperature_c: number | null
          trip_id: string
          vineyard_id: string
          wind_direction_deg: number | null
          wind_gust_kmh: number | null
          wind_speed_kmh: number | null
        }
        Insert: {
          captured_at?: string
          humidity_pct?: number | null
          id?: string
          is_stale?: boolean
          observed_at?: string | null
          provider?: string | null
          provider_record_id?: string | null
          rain_mm?: number | null
          retrieval_mode?: string
          retrieved_at?: string
          sample_slot: string
          source: string
          source_kind: string
          station_id?: string | null
          station_name?: string | null
          temperature_c?: number | null
          trip_id: string
          vineyard_id: string
          wind_direction_deg?: number | null
          wind_gust_kmh?: number | null
          wind_speed_kmh?: number | null
        }
        Update: {
          captured_at?: string
          humidity_pct?: number | null
          id?: string
          is_stale?: boolean
          observed_at?: string | null
          provider?: string | null
          provider_record_id?: string | null
          rain_mm?: number | null
          retrieval_mode?: string
          retrieved_at?: string
          sample_slot?: string
          source?: string
          source_kind?: string
          station_id?: string | null
          station_name?: string | null
          temperature_c?: number | null
          trip_id?: string
          vineyard_id?: string
          wind_direction_deg?: number | null
          wind_gust_kmh?: number | null
          wind_speed_kmh?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "trip_weather_observations_trip_id_fkey"
            columns: ["trip_id"]
            isOneToOne: false
            referencedRelation: "trips"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "trip_weather_observations_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      trip_weather_retrieval_attempts: {
        Row: {
          humidity_pct: number | null
          id: string
          is_stale: boolean | null
          observed_at: string | null
          outcome: string
          provider: string
          provider_record_id: string | null
          rain_mm: number | null
          retrieval_mode: string
          retrieved_at: string
          sample_slot: string
          source: string | null
          station_id: string | null
          station_name: string | null
          temperature_c: number | null
          trip_id: string
          vineyard_id: string
          wind_direction_deg: number | null
          wind_gust_kmh: number | null
          wind_speed_kmh: number | null
        }
        Insert: {
          humidity_pct?: number | null
          id?: string
          is_stale?: boolean | null
          observed_at?: string | null
          outcome: string
          provider: string
          provider_record_id?: string | null
          rain_mm?: number | null
          retrieval_mode: string
          retrieved_at?: string
          sample_slot: string
          source?: string | null
          station_id?: string | null
          station_name?: string | null
          temperature_c?: number | null
          trip_id: string
          vineyard_id: string
          wind_direction_deg?: number | null
          wind_gust_kmh?: number | null
          wind_speed_kmh?: number | null
        }
        Update: {
          humidity_pct?: number | null
          id?: string
          is_stale?: boolean | null
          observed_at?: string | null
          outcome?: string
          provider?: string
          provider_record_id?: string | null
          rain_mm?: number | null
          retrieval_mode?: string
          retrieved_at?: string
          sample_slot?: string
          source?: string | null
          station_id?: string | null
          station_name?: string | null
          temperature_c?: number | null
          trip_id?: string
          vineyard_id?: string
          wind_direction_deg?: number | null
          wind_gust_kmh?: number | null
          wind_speed_kmh?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "trip_weather_retrieval_attempts_trip_id_fkey"
            columns: ["trip_id"]
            isOneToOne: false
            referencedRelation: "trips"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "trip_weather_retrieval_attempts_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      trips: {
        Row: {
          active_tank_number: number | null
          client_updated_at: string | null
          completed_paths: Json | null
          completion_notes: string | null
          created_at: string
          created_by: string | null
          current_path_distance: number | null
          current_row_number: number | null
          deleted_at: string | null
          end_engine_hours: number | null
          end_time: string | null
          entry_source: string | null
          filling_tank_number: number | null
          id: string
          is_active: boolean
          is_filling_tank: boolean | null
          is_paused: boolean
          machine_id: string | null
          manual_correction_events: Json | null
          manual_entry_id: string | null
          next_row_number: number | null
          occurrence_coverage: Json | null
          operator_user_id: string | null
          paddock_id: string | null
          paddock_ids: Json | null
          paddock_name: string | null
          path_points: Json | null
          pause_timestamps: Json | null
          person_name: string | null
          pin_ids: Json | null
          resume_timestamps: Json | null
          row_sequence: Json | null
          seeding_details: Json | null
          sequence_index: number | null
          skipped_paths: Json | null
          start_engine_hours: number | null
          start_time: string | null
          sync_version: number
          tank_sessions: Json | null
          total_distance: number | null
          total_tanks: number | null
          tracking_pattern: string | null
          tractor_id: string | null
          trip_function: string | null
          trip_title: string | null
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          work_task_id: string | null
          worker_type_id: string | null
        }
        Insert: {
          active_tank_number?: number | null
          client_updated_at?: string | null
          completed_paths?: Json | null
          completion_notes?: string | null
          created_at?: string
          created_by?: string | null
          current_path_distance?: number | null
          current_row_number?: number | null
          deleted_at?: string | null
          end_engine_hours?: number | null
          end_time?: string | null
          entry_source?: string | null
          filling_tank_number?: number | null
          id?: string
          is_active?: boolean
          is_filling_tank?: boolean | null
          is_paused?: boolean
          machine_id?: string | null
          manual_correction_events?: Json | null
          manual_entry_id?: string | null
          next_row_number?: number | null
          occurrence_coverage?: Json | null
          operator_user_id?: string | null
          paddock_id?: string | null
          paddock_ids?: Json | null
          paddock_name?: string | null
          path_points?: Json | null
          pause_timestamps?: Json | null
          person_name?: string | null
          pin_ids?: Json | null
          resume_timestamps?: Json | null
          row_sequence?: Json | null
          seeding_details?: Json | null
          sequence_index?: number | null
          skipped_paths?: Json | null
          start_engine_hours?: number | null
          start_time?: string | null
          sync_version?: number
          tank_sessions?: Json | null
          total_distance?: number | null
          total_tanks?: number | null
          tracking_pattern?: string | null
          tractor_id?: string | null
          trip_function?: string | null
          trip_title?: string | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
          work_task_id?: string | null
          worker_type_id?: string | null
        }
        Update: {
          active_tank_number?: number | null
          client_updated_at?: string | null
          completed_paths?: Json | null
          completion_notes?: string | null
          created_at?: string
          created_by?: string | null
          current_path_distance?: number | null
          current_row_number?: number | null
          deleted_at?: string | null
          end_engine_hours?: number | null
          end_time?: string | null
          entry_source?: string | null
          filling_tank_number?: number | null
          id?: string
          is_active?: boolean
          is_filling_tank?: boolean | null
          is_paused?: boolean
          machine_id?: string | null
          manual_correction_events?: Json | null
          manual_entry_id?: string | null
          next_row_number?: number | null
          occurrence_coverage?: Json | null
          operator_user_id?: string | null
          paddock_id?: string | null
          paddock_ids?: Json | null
          paddock_name?: string | null
          path_points?: Json | null
          pause_timestamps?: Json | null
          person_name?: string | null
          pin_ids?: Json | null
          resume_timestamps?: Json | null
          row_sequence?: Json | null
          seeding_details?: Json | null
          sequence_index?: number | null
          skipped_paths?: Json | null
          start_engine_hours?: number | null
          start_time?: string | null
          sync_version?: number
          tank_sessions?: Json | null
          total_distance?: number | null
          total_tanks?: number | null
          tracking_pattern?: string | null
          tractor_id?: string | null
          trip_function?: string | null
          trip_title?: string | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
          work_task_id?: string | null
          worker_type_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "trips_machine_id_fkey"
            columns: ["machine_id"]
            isOneToOne: false
            referencedRelation: "vineyard_machines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "trips_operator_category_id_fkey"
            columns: ["worker_type_id"]
            isOneToOne: false
            referencedRelation: "operator_categories"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "trips_operator_category_id_fkey"
            columns: ["worker_type_id"]
            isOneToOne: false
            referencedRelation: "worker_types"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "trips_paddock_id_fkey"
            columns: ["paddock_id"]
            isOneToOne: false
            referencedRelation: "paddocks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "trips_tractor_id_fkey"
            columns: ["tractor_id"]
            isOneToOne: false
            referencedRelation: "tractors"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "trips_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "trips_work_task_id_fkey"
            columns: ["work_task_id"]
            isOneToOne: false
            referencedRelation: "v_work_task_effective_labour_cost"
            referencedColumns: ["work_task_id"]
          },
          {
            foreignKeyName: "trips_work_task_id_fkey"
            columns: ["work_task_id"]
            isOneToOne: false
            referencedRelation: "work_tasks"
            referencedColumns: ["id"]
          },
        ]
      }
      user_operational_tool_preferences: {
        Row: {
          created_at: string
          hidden_tool_ids: string[]
          preference_version: number
          updated_at: string
          user_id: string
          visible_tool_ids: string[]
        }
        Insert: {
          created_at?: string
          hidden_tool_ids?: string[]
          preference_version?: number
          updated_at?: string
          user_id: string
          visible_tool_ids?: string[]
        }
        Update: {
          created_at?: string
          hidden_tool_ids?: string[]
          preference_version?: number
          updated_at?: string
          user_id?: string
          visible_tool_ids?: string[]
        }
        Relationships: []
      }
      vinetrack_account_trials: {
        Row: {
          created_at: string
          migrated_at: string | null
          revoked_by: string | null
          revoked_reason: string | null
          source: string
          status: string
          trial_ends_at: string
          trial_started_at: string
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          migrated_at?: string | null
          revoked_by?: string | null
          revoked_reason?: string | null
          source?: string
          status?: string
          trial_ends_at: string
          trial_started_at: string
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          migrated_at?: string | null
          revoked_by?: string | null
          revoked_reason?: string | null
          source?: string
          status?: string
          trial_ends_at?: string
          trial_started_at?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      vinetrack_billing_events: {
        Row: {
          created_at: string
          event_type: string
          external_event_id: string | null
          id: string
          owner_user_id: string | null
          payload: Json
          provider: string
          subscription_id: string | null
        }
        Insert: {
          created_at?: string
          event_type: string
          external_event_id?: string | null
          id?: string
          owner_user_id?: string | null
          payload?: Json
          provider: string
          subscription_id?: string | null
        }
        Update: {
          created_at?: string
          event_type?: string
          external_event_id?: string | null
          id?: string
          owner_user_id?: string | null
          payload?: Json
          provider?: string
          subscription_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "vinetrack_billing_events_subscription_id_fkey"
            columns: ["subscription_id"]
            isOneToOne: false
            referencedRelation: "vinetrack_subscriptions"
            referencedColumns: ["id"]
          },
        ]
      }
      vinetrack_entitlement_audit: {
        Row: {
          app_version: string | null
          created_at: string
          event_type: string
          id: string
          new_state: Json | null
          platform: string | null
          previous_state: Json | null
          user_id: string
        }
        Insert: {
          app_version?: string | null
          created_at?: string
          event_type: string
          id?: string
          new_state?: Json | null
          platform?: string | null
          previous_state?: Json | null
          user_id: string
        }
        Update: {
          app_version?: string | null
          created_at?: string
          event_type?: string
          id?: string
          new_state?: Json | null
          platform?: string | null
          previous_state?: Json | null
          user_id?: string
        }
        Relationships: []
      }
      vinetrack_entitlement_state: {
        Row: {
          access_source: string
          has_access: boolean
          plan_code: string | null
          reason_code: string
          updated_at: string
          user_id: string
        }
        Insert: {
          access_source: string
          has_access: boolean
          plan_code?: string | null
          reason_code: string
          updated_at?: string
          user_id: string
        }
        Update: {
          access_source?: string
          has_access?: boolean
          plan_code?: string | null
          reason_code?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      vinetrack_invoice_records: {
        Row: {
          amount_due_cents: number | null
          amount_paid_cents: number | null
          created_at: string
          currency: string
          description: string | null
          due_at: string | null
          external_customer_id: string | null
          external_invoice_id: string | null
          external_subscription_id: string | null
          hosted_invoice_url: string | null
          id: string
          invoice_number: string | null
          invoice_pdf_url: string | null
          issued_at: string | null
          last_synced_at: string | null
          metadata: Json
          metadata_safe: Json
          owner_user_id: string | null
          paid_at: string | null
          period_end: string | null
          period_start: string | null
          provider: string
          refunded_at: string | null
          status: string
          subscription_id: string | null
          subtotal_cents: number | null
          tax_cents: number | null
          total_cents: number | null
          updated_at: string
          vineyard_id: string | null
          voided_at: string | null
        }
        Insert: {
          amount_due_cents?: number | null
          amount_paid_cents?: number | null
          created_at?: string
          currency?: string
          description?: string | null
          due_at?: string | null
          external_customer_id?: string | null
          external_invoice_id?: string | null
          external_subscription_id?: string | null
          hosted_invoice_url?: string | null
          id?: string
          invoice_number?: string | null
          invoice_pdf_url?: string | null
          issued_at?: string | null
          last_synced_at?: string | null
          metadata?: Json
          metadata_safe?: Json
          owner_user_id?: string | null
          paid_at?: string | null
          period_end?: string | null
          period_start?: string | null
          provider?: string
          refunded_at?: string | null
          status?: string
          subscription_id?: string | null
          subtotal_cents?: number | null
          tax_cents?: number | null
          total_cents?: number | null
          updated_at?: string
          vineyard_id?: string | null
          voided_at?: string | null
        }
        Update: {
          amount_due_cents?: number | null
          amount_paid_cents?: number | null
          created_at?: string
          currency?: string
          description?: string | null
          due_at?: string | null
          external_customer_id?: string | null
          external_invoice_id?: string | null
          external_subscription_id?: string | null
          hosted_invoice_url?: string | null
          id?: string
          invoice_number?: string | null
          invoice_pdf_url?: string | null
          issued_at?: string | null
          last_synced_at?: string | null
          metadata?: Json
          metadata_safe?: Json
          owner_user_id?: string | null
          paid_at?: string | null
          period_end?: string | null
          period_start?: string | null
          provider?: string
          refunded_at?: string | null
          status?: string
          subscription_id?: string | null
          subtotal_cents?: number | null
          tax_cents?: number | null
          total_cents?: number | null
          updated_at?: string
          vineyard_id?: string | null
          voided_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "vinetrack_invoice_records_subscription_id_fkey"
            columns: ["subscription_id"]
            isOneToOne: false
            referencedRelation: "vinetrack_subscriptions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vinetrack_invoice_records_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vinetrack_plans: {
        Row: {
          additional_user_price_cents: number | null
          apple_product_ids: string[] | null
          available_from: string | null
          available_until: string | null
          base_price_cents: number | null
          billing_cycle: string
          billing_provider: string
          code: string
          created_at: string
          currency: string
          description: string | null
          id: string
          included_user_licences: number | null
          is_active: boolean
          is_price_from: boolean
          max_user_licences: number | null
          metadata: Json
          name: string
          portal_access_level: string
          revenuecat_entitlement: string | null
          stripe_price_id: string | null
          tax_mode: string
          tier: string
          trial_days: number
          updated_at: string
        }
        Insert: {
          additional_user_price_cents?: number | null
          apple_product_ids?: string[] | null
          available_from?: string | null
          available_until?: string | null
          base_price_cents?: number | null
          billing_cycle: string
          billing_provider: string
          code: string
          created_at?: string
          currency?: string
          description?: string | null
          id?: string
          included_user_licences?: number | null
          is_active?: boolean
          is_price_from?: boolean
          max_user_licences?: number | null
          metadata?: Json
          name: string
          portal_access_level?: string
          revenuecat_entitlement?: string | null
          stripe_price_id?: string | null
          tax_mode?: string
          tier: string
          trial_days?: number
          updated_at?: string
        }
        Update: {
          additional_user_price_cents?: number | null
          apple_product_ids?: string[] | null
          available_from?: string | null
          available_until?: string | null
          base_price_cents?: number | null
          billing_cycle?: string
          billing_provider?: string
          code?: string
          created_at?: string
          currency?: string
          description?: string | null
          id?: string
          included_user_licences?: number | null
          is_active?: boolean
          is_price_from?: boolean
          max_user_licences?: number | null
          metadata?: Json
          name?: string
          portal_access_level?: string
          revenuecat_entitlement?: string | null
          stripe_price_id?: string | null
          tax_mode?: string
          tier?: string
          trial_days?: number
          updated_at?: string
        }
        Relationships: []
      }
      vinetrack_subscriptions: {
        Row: {
          billing_provider: string
          cancel_at_period_end: boolean
          canceled_at: string | null
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          current_period_end: string | null
          current_period_start: string | null
          deleted_at: string | null
          environment: string | null
          expired_at: string | null
          external_subscription_id: string | null
          external_transaction_id: string | null
          grace_period_end: string | null
          grant_scope: string
          id: string
          last_provider_event: string | null
          last_provider_event_at: string | null
          last_verified_at: string | null
          manual_grant_expires_at: string | null
          manual_grant_reason: string | null
          manual_grant_revoked_at: string | null
          manual_grant_revoked_by: string | null
          manual_grant_type: string | null
          metadata: Json
          notes: string | null
          owner_user_id: string
          plan_id: string
          platform: string | null
          primary_vineyard_id: string | null
          revenuecat_app_user_id: string | null
          revenuecat_entitlement: string | null
          seats_included: number
          seats_purchased: number
          started_at: string | null
          status: string
          stripe_customer_id: string | null
          stripe_subscription_id: string | null
          sync_version: number
          trial_end: string | null
          trial_start: string | null
          unlimited_licences: boolean
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          billing_provider: string
          cancel_at_period_end?: boolean
          canceled_at?: string | null
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          current_period_end?: string | null
          current_period_start?: string | null
          deleted_at?: string | null
          environment?: string | null
          expired_at?: string | null
          external_subscription_id?: string | null
          external_transaction_id?: string | null
          grace_period_end?: string | null
          grant_scope?: string
          id?: string
          last_provider_event?: string | null
          last_provider_event_at?: string | null
          last_verified_at?: string | null
          manual_grant_expires_at?: string | null
          manual_grant_reason?: string | null
          manual_grant_revoked_at?: string | null
          manual_grant_revoked_by?: string | null
          manual_grant_type?: string | null
          metadata?: Json
          notes?: string | null
          owner_user_id: string
          plan_id: string
          platform?: string | null
          primary_vineyard_id?: string | null
          revenuecat_app_user_id?: string | null
          revenuecat_entitlement?: string | null
          seats_included?: number
          seats_purchased?: number
          started_at?: string | null
          status?: string
          stripe_customer_id?: string | null
          stripe_subscription_id?: string | null
          sync_version?: number
          trial_end?: string | null
          trial_start?: string | null
          unlimited_licences?: boolean
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          billing_provider?: string
          cancel_at_period_end?: boolean
          canceled_at?: string | null
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          current_period_end?: string | null
          current_period_start?: string | null
          deleted_at?: string | null
          environment?: string | null
          expired_at?: string | null
          external_subscription_id?: string | null
          external_transaction_id?: string | null
          grace_period_end?: string | null
          grant_scope?: string
          id?: string
          last_provider_event?: string | null
          last_provider_event_at?: string | null
          last_verified_at?: string | null
          manual_grant_expires_at?: string | null
          manual_grant_reason?: string | null
          manual_grant_revoked_at?: string | null
          manual_grant_revoked_by?: string | null
          manual_grant_type?: string | null
          metadata?: Json
          notes?: string | null
          owner_user_id?: string
          plan_id?: string
          platform?: string | null
          primary_vineyard_id?: string | null
          revenuecat_app_user_id?: string | null
          revenuecat_entitlement?: string | null
          seats_included?: number
          seats_purchased?: number
          started_at?: string | null
          status?: string
          stripe_customer_id?: string | null
          stripe_subscription_id?: string | null
          sync_version?: number
          trial_end?: string | null
          trial_start?: string | null
          unlimited_licences?: boolean
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "vinetrack_subscriptions_plan_id_fkey"
            columns: ["plan_id"]
            isOneToOne: false
            referencedRelation: "vinetrack_plans"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vinetrack_subscriptions_primary_vineyard_id_fkey"
            columns: ["primary_vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vinetrack_user_clients: {
        Row: {
          app_build: string | null
          app_type: string
          app_version: string | null
          browser_name: string | null
          browser_version: string | null
          client_instance_id: string
          created_at: string
          device_family: string | null
          device_model: string | null
          first_seen_at: string
          id: string
          last_authenticated_at: string | null
          last_seen_at: string
          last_vineyard_id: string | null
          os_name: string | null
          os_version: string | null
          platform: string
          updated_at: string
          user_id: string
        }
        Insert: {
          app_build?: string | null
          app_type: string
          app_version?: string | null
          browser_name?: string | null
          browser_version?: string | null
          client_instance_id: string
          created_at?: string
          device_family?: string | null
          device_model?: string | null
          first_seen_at?: string
          id?: string
          last_authenticated_at?: string | null
          last_seen_at?: string
          last_vineyard_id?: string | null
          os_name?: string | null
          os_version?: string | null
          platform: string
          updated_at?: string
          user_id: string
        }
        Update: {
          app_build?: string | null
          app_type?: string
          app_version?: string | null
          browser_name?: string | null
          browser_version?: string | null
          client_instance_id?: string
          created_at?: string
          device_family?: string | null
          device_model?: string | null
          first_seen_at?: string
          id?: string
          last_authenticated_at?: string | null
          last_seen_at?: string
          last_vineyard_id?: string | null
          os_name?: string | null
          os_version?: string | null
          platform?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vinetrack_user_clients_last_vineyard_id_fkey"
            columns: ["last_vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vinetrack_user_licences: {
        Row: {
          assigned_at: string
          assigned_by: string | null
          created_at: string
          id: string
          invited_email: string | null
          metadata: Json
          revoked_at: string | null
          status: string
          subscription_id: string
          updated_at: string
          user_id: string | null
          vineyard_id: string | null
        }
        Insert: {
          assigned_at?: string
          assigned_by?: string | null
          created_at?: string
          id?: string
          invited_email?: string | null
          metadata?: Json
          revoked_at?: string | null
          status?: string
          subscription_id: string
          updated_at?: string
          user_id?: string | null
          vineyard_id?: string | null
        }
        Update: {
          assigned_at?: string
          assigned_by?: string | null
          created_at?: string
          id?: string
          invited_email?: string | null
          metadata?: Json
          revoked_at?: string | null
          status?: string
          subscription_id?: string
          updated_at?: string
          user_id?: string | null
          vineyard_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "vinetrack_user_licences_subscription_id_fkey"
            columns: ["subscription_id"]
            isOneToOne: false
            referencedRelation: "vinetrack_subscriptions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vinetrack_user_licences_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vineyard_alert_preferences: {
        Row: {
          aged_pin_alerts_enabled: boolean
          aged_pin_days: number
          disease_alerts_enabled: boolean
          disease_botrytis_enabled: boolean
          disease_downy_enabled: boolean
          disease_powdery_enabled: boolean
          disease_use_measured_wetness: boolean
          frost_alert_threshold_c: number
          heat_alert_threshold_c: number
          irrigation_alerts_enabled: boolean
          irrigation_deficit_threshold_mm: number
          irrigation_forecast_days: number
          push_enabled: boolean
          quiet_hours_end: string | null
          quiet_hours_start: string | null
          rain_alert_threshold_mm: number
          spray_job_reminders_enabled: boolean
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          weather_alerts_enabled: boolean
          wind_alert_threshold_kmh: number
        }
        Insert: {
          aged_pin_alerts_enabled?: boolean
          aged_pin_days?: number
          disease_alerts_enabled?: boolean
          disease_botrytis_enabled?: boolean
          disease_downy_enabled?: boolean
          disease_powdery_enabled?: boolean
          disease_use_measured_wetness?: boolean
          frost_alert_threshold_c?: number
          heat_alert_threshold_c?: number
          irrigation_alerts_enabled?: boolean
          irrigation_deficit_threshold_mm?: number
          irrigation_forecast_days?: number
          push_enabled?: boolean
          quiet_hours_end?: string | null
          quiet_hours_start?: string | null
          rain_alert_threshold_mm?: number
          spray_job_reminders_enabled?: boolean
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
          weather_alerts_enabled?: boolean
          wind_alert_threshold_kmh?: number
        }
        Update: {
          aged_pin_alerts_enabled?: boolean
          aged_pin_days?: number
          disease_alerts_enabled?: boolean
          disease_botrytis_enabled?: boolean
          disease_downy_enabled?: boolean
          disease_powdery_enabled?: boolean
          disease_use_measured_wetness?: boolean
          frost_alert_threshold_c?: number
          heat_alert_threshold_c?: number
          irrigation_alerts_enabled?: boolean
          irrigation_deficit_threshold_mm?: number
          irrigation_forecast_days?: number
          push_enabled?: boolean
          quiet_hours_end?: string | null
          quiet_hours_start?: string | null
          rain_alert_threshold_mm?: number
          spray_job_reminders_enabled?: boolean
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
          weather_alerts_enabled?: boolean
          wind_alert_threshold_kmh?: number
        }
        Relationships: [
          {
            foreignKeyName: "vineyard_alert_preferences_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: true
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vineyard_alert_user_status: {
        Row: {
          alert_id: string
          dismissed_at: string | null
          read_at: string | null
          updated_at: string
          user_id: string
        }
        Insert: {
          alert_id: string
          dismissed_at?: string | null
          read_at?: string | null
          updated_at?: string
          user_id: string
        }
        Update: {
          alert_id?: string
          dismissed_at?: string | null
          read_at?: string | null
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vineyard_alert_user_status_alert_id_fkey"
            columns: ["alert_id"]
            isOneToOne: false
            referencedRelation: "vineyard_alerts"
            referencedColumns: ["id"]
          },
        ]
      }
      vineyard_alerts: {
        Row: {
          action: string | null
          alert_type: string
          created_at: string
          created_by: string | null
          dedup_key: string
          expires_at: string | null
          generated_for_date: string | null
          id: string
          message: string
          paddock_id: string | null
          payload: Json
          related_id: string | null
          related_table: string | null
          severity: string
          title: string
          updated_at: string
          vineyard_id: string
        }
        Insert: {
          action?: string | null
          alert_type: string
          created_at?: string
          created_by?: string | null
          dedup_key: string
          expires_at?: string | null
          generated_for_date?: string | null
          id?: string
          message: string
          paddock_id?: string | null
          payload?: Json
          related_id?: string | null
          related_table?: string | null
          severity?: string
          title: string
          updated_at?: string
          vineyard_id: string
        }
        Update: {
          action?: string | null
          alert_type?: string
          created_at?: string
          created_by?: string | null
          dedup_key?: string
          expires_at?: string | null
          generated_for_date?: string | null
          id?: string
          message?: string
          paddock_id?: string | null
          payload?: Json
          related_id?: string | null
          related_table?: string | null
          severity?: string
          title?: string
          updated_at?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vineyard_alerts_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vineyard_button_configs: {
        Row: {
          client_updated_at: string | null
          config_data: Json
          config_type: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          sync_version: number
          updated_at: string
          updated_by: string | null
          vineyard_id: string
        }
        Insert: {
          client_updated_at?: string | null
          config_data?: Json
          config_type: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
        }
        Update: {
          client_updated_at?: string | null
          config_data?: Json
          config_type?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vineyard_button_configs_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vineyard_custom_pin_types: {
        Row: {
          color: string | null
          created_at: string
          created_by: string | null
          icon: string | null
          id: string
          is_active: boolean
          name: string
          updated_at: string
          vineyard_id: string
        }
        Insert: {
          color?: string | null
          created_at?: string
          created_by?: string | null
          icon?: string | null
          id: string
          is_active?: boolean
          name: string
          updated_at?: string
          vineyard_id: string
        }
        Update: {
          color?: string | null
          created_at?: string
          created_by?: string | null
          icon?: string | null
          id?: string
          is_active?: boolean
          name?: string
          updated_at?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vineyard_custom_pin_types_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vineyard_external_resources: {
        Row: {
          contact_name: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          email: string | null
          id: string
          is_active: boolean
          kind: string
          name: string
          notes: string | null
          phone: string | null
          updated_at: string
          vineyard_id: string
        }
        Insert: {
          contact_name?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          email?: string | null
          id?: string
          is_active?: boolean
          kind: string
          name: string
          notes?: string | null
          phone?: string | null
          updated_at?: string
          vineyard_id: string
        }
        Update: {
          contact_name?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          email?: string | null
          id?: string
          is_active?: boolean
          kind?: string
          name?: string
          notes?: string | null
          phone?: string | null
          updated_at?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vineyard_external_resources_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vineyard_forecast_cache: {
        Row: {
          created_at: string
          fetched_at: string
          id: string
          payload: Json
          provider: string
          provider_location_ref: string | null
          provider_updated_at: string | null
          schema_version: string
          stale_at: string
          timezone: string | null
          updated_at: string
          vineyard_id: string
        }
        Insert: {
          created_at?: string
          fetched_at?: string
          id?: string
          payload: Json
          provider: string
          provider_location_ref?: string | null
          provider_updated_at?: string | null
          schema_version: string
          stale_at: string
          timezone?: string | null
          updated_at?: string
          vineyard_id: string
        }
        Update: {
          created_at?: string
          fetched_at?: string
          id?: string
          payload?: Json
          provider?: string
          provider_location_ref?: string | null
          provider_updated_at?: string | null
          schema_version?: string
          stale_at?: string
          timezone?: string | null
          updated_at?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vineyard_forecast_cache_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vineyard_grape_clones: {
        Row: {
          clone_key: string
          created_at: string
          display_name: string
          id: string
          is_active: boolean
          is_custom: boolean
          updated_at: string
          variety_key: string
          vineyard_id: string
        }
        Insert: {
          clone_key: string
          created_at?: string
          display_name: string
          id?: string
          is_active?: boolean
          is_custom?: boolean
          updated_at?: string
          variety_key: string
          vineyard_id: string
        }
        Update: {
          clone_key?: string
          created_at?: string
          display_name?: string
          id?: string
          is_active?: boolean
          is_custom?: boolean
          updated_at?: string
          variety_key?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vineyard_grape_clones_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vineyard_grape_varieties: {
        Row: {
          created_at: string
          display_name: string
          id: string
          is_active: boolean
          is_custom: boolean
          optimal_gdd_override: number | null
          updated_at: string
          variety_key: string
          vineyard_id: string
        }
        Insert: {
          created_at?: string
          display_name: string
          id?: string
          is_active?: boolean
          is_custom?: boolean
          optimal_gdd_override?: number | null
          updated_at?: string
          variety_key: string
          vineyard_id: string
        }
        Update: {
          created_at?: string
          display_name?: string
          id?: string
          is_active?: boolean
          is_custom?: boolean
          optimal_gdd_override?: number | null
          updated_at?: string
          variety_key?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vineyard_grape_varieties_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vineyard_growth_stage_images: {
        Row: {
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          image_path: string
          stage_code: string
          sync_version: number
          updated_at: string
          updated_by: string | null
          vineyard_id: string
        }
        Insert: {
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          image_path: string
          stage_code: string
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
        }
        Update: {
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          image_path?: string
          stage_code?: string
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vineyard_growth_stage_images_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vineyard_insights_deletions: {
        Row: {
          deleted_at: string
          deleted_by: string
          entity_id: string
          entity_type: string
          id: string
          operation_id: string
          vineyard_id: string
        }
        Insert: {
          deleted_at?: string
          deleted_by: string
          entity_id: string
          entity_type: string
          id?: string
          operation_id: string
          vineyard_id: string
        }
        Update: {
          deleted_at?: string
          deleted_by?: string
          entity_id?: string
          entity_type?: string
          id?: string
          operation_id?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vineyard_insights_deletions_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vineyard_machines: {
        Row: {
          available_for_job_costing: boolean
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          fuel_tracking_enabled: boolean
          fuel_usage_l_per_hour: number
          id: string
          legacy_tractor_id: string | null
          machine_type: string
          name: string
          notes: string | null
          serial_number: string | null
          sync_version: number
          updated_at: string
          updated_by: string | null
          vin_number: string | null
          vineyard_id: string
        }
        Insert: {
          available_for_job_costing?: boolean
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          fuel_tracking_enabled?: boolean
          fuel_usage_l_per_hour?: number
          id?: string
          legacy_tractor_id?: string | null
          machine_type?: string
          name?: string
          notes?: string | null
          serial_number?: string | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vin_number?: string | null
          vineyard_id: string
        }
        Update: {
          available_for_job_costing?: boolean
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          fuel_tracking_enabled?: boolean
          fuel_usage_l_per_hour?: number
          id?: string
          legacy_tractor_id?: string | null
          machine_type?: string
          name?: string
          notes?: string | null
          serial_number?: string | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vin_number?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vineyard_machines_legacy_tractor_id_fkey"
            columns: ["legacy_tractor_id"]
            isOneToOne: false
            referencedRelation: "tractors"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vineyard_machines_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vineyard_materials: {
        Row: {
          base_material_id: string | null
          category: string
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          default_unit_cost: number | null
          deleted_at: string | null
          id: string
          is_active: boolean
          is_custom: boolean
          name: string
          sync_version: number
          unit: string
          updated_at: string
          updated_by: string | null
          vineyard_id: string
        }
        Insert: {
          base_material_id?: string | null
          category?: string
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          default_unit_cost?: number | null
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          is_custom?: boolean
          name: string
          sync_version?: number
          unit: string
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
        }
        Update: {
          base_material_id?: string | null
          category?: string
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          default_unit_cost?: number | null
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          is_custom?: boolean
          name?: string
          sync_version?: number
          unit?: string
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vineyard_materials_base_material_id_fkey"
            columns: ["base_material_id"]
            isOneToOne: false
            referencedRelation: "material_catalogue"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vineyard_materials_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vineyard_members: {
        Row: {
          display_name: string | null
          id: string
          joined_at: string
          role: string
          user_id: string
          vineyard_id: string
          worker_type_id: string | null
        }
        Insert: {
          display_name?: string | null
          id?: string
          joined_at?: string
          role: string
          user_id: string
          vineyard_id: string
          worker_type_id?: string | null
        }
        Update: {
          display_name?: string | null
          id?: string
          joined_at?: string
          role?: string
          user_id?: string
          vineyard_id?: string
          worker_type_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "vineyard_members_operator_category_id_fkey"
            columns: ["worker_type_id"]
            isOneToOne: false
            referencedRelation: "operator_categories"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vineyard_members_operator_category_id_fkey"
            columns: ["worker_type_id"]
            isOneToOne: false
            referencedRelation: "worker_types"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vineyard_members_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vineyard_members_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vineyard_rootstocks: {
        Row: {
          created_at: string
          display_name: string
          id: string
          is_active: boolean
          is_custom: boolean
          rootstock_key: string
          updated_at: string
          vineyard_id: string
        }
        Insert: {
          created_at?: string
          display_name: string
          id?: string
          is_active?: boolean
          is_custom?: boolean
          rootstock_key: string
          updated_at?: string
          vineyard_id: string
        }
        Update: {
          created_at?: string
          display_name?: string
          id?: string
          is_active?: boolean
          is_custom?: boolean
          rootstock_key?: string
          updated_at?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vineyard_rootstocks_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vineyard_spray_targets: {
        Row: {
          created_at: string
          created_by: string | null
          id: string
          identifier: string
          is_active: boolean
          label: string
          updated_at: string
          vineyard_id: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          id: string
          identifier: string
          is_active?: boolean
          label: string
          updated_at?: string
          vineyard_id: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          id?: string
          identifier?: string
          is_active?: boolean
          label?: string
          updated_at?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vineyard_spray_targets_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vineyard_trip_functions: {
        Row: {
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          is_active: boolean
          label: string
          slug: string
          sort_order: number
          updated_at: string
          updated_by: string | null
          vineyard_id: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          label: string
          slug: string
          sort_order?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          label?: string
          slug?: string
          sort_order?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vineyard_trip_functions_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vineyard_weather_integrations: {
        Row: {
          api_key: string | null
          api_secret: string | null
          configured_by: string | null
          detected_sensors: string[]
          has_leaf_wetness: boolean
          has_rain: boolean
          has_temperature_humidity: boolean
          has_wind: boolean
          id: string
          is_active: boolean
          last_test_status: string | null
          last_tested_at: string | null
          provider: string
          station_id: string | null
          station_latitude: number | null
          station_longitude: number | null
          station_name: string | null
          updated_at: string
          vineyard_id: string
        }
        Insert: {
          api_key?: string | null
          api_secret?: string | null
          configured_by?: string | null
          detected_sensors?: string[]
          has_leaf_wetness?: boolean
          has_rain?: boolean
          has_temperature_humidity?: boolean
          has_wind?: boolean
          id?: string
          is_active?: boolean
          last_test_status?: string | null
          last_tested_at?: string | null
          provider: string
          station_id?: string | null
          station_latitude?: number | null
          station_longitude?: number | null
          station_name?: string | null
          updated_at?: string
          vineyard_id: string
        }
        Update: {
          api_key?: string | null
          api_secret?: string | null
          configured_by?: string | null
          detected_sensors?: string[]
          has_leaf_wetness?: boolean
          has_rain?: boolean
          has_temperature_humidity?: boolean
          has_wind?: boolean
          id?: string
          is_active?: boolean
          last_test_status?: string | null
          last_tested_at?: string | null
          provider?: string
          station_id?: string | null
          station_latitude?: number | null
          station_longitude?: number | null
          station_name?: string | null
          updated_at?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vineyard_weather_integrations_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vineyard_weather_observations: {
        Row: {
          fetched_at: string
          humidity_pct: number | null
          id: string
          leaf_wetness: number | null
          observed_at: string
          rain_rate_mm_per_hr: number | null
          rain_today_mm: number | null
          raw_payload: Json | null
          source: string
          station_id: string | null
          station_name: string | null
          temperature_c: number | null
          vineyard_id: string
          wind_direction_deg: number | null
          wind_gust_kmh: number | null
          wind_speed_kmh: number | null
        }
        Insert: {
          fetched_at?: string
          humidity_pct?: number | null
          id?: string
          leaf_wetness?: number | null
          observed_at: string
          rain_rate_mm_per_hr?: number | null
          rain_today_mm?: number | null
          raw_payload?: Json | null
          source: string
          station_id?: string | null
          station_name?: string | null
          temperature_c?: number | null
          vineyard_id: string
          wind_direction_deg?: number | null
          wind_gust_kmh?: number | null
          wind_speed_kmh?: number | null
        }
        Update: {
          fetched_at?: string
          humidity_pct?: number | null
          id?: string
          leaf_wetness?: number | null
          observed_at?: string
          rain_rate_mm_per_hr?: number | null
          rain_today_mm?: number | null
          raw_payload?: Json | null
          source?: string
          station_id?: string | null
          station_name?: string | null
          temperature_c?: number | null
          vineyard_id?: string
          wind_direction_deg?: number | null
          wind_gust_kmh?: number | null
          wind_speed_kmh?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "vineyard_weather_observations_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vineyards: {
        Row: {
          area_unit: string | null
          country: string | null
          country_code: string | null
          created_at: string
          currency_code: string | null
          current_observation_provider: string | null
          date_format: string | null
          deleted_at: string | null
          distance_unit: string | null
          elevation_metres: number | null
          forecast_provider: string
          fuel_unit: string | null
          id: string
          irrigation_recent_rain_lookback_hours: number
          latitude: number | null
          logo_path: string | null
          logo_updated_at: string | null
          longitude: number | null
          name: string
          owner_id: string | null
          season_start_day: number
          season_start_month: number
          spray_carrier_volume_basis: string | null
          spray_compliance_profile: string | null
          spray_rate_area_unit: string | null
          sugar_measurement_unit: string | null
          terminology_region: string | null
          timezone: string | null
          updated_at: string
          volume_unit: string | null
          yield_samples_per_hectare: number
        }
        Insert: {
          area_unit?: string | null
          country?: string | null
          country_code?: string | null
          created_at?: string
          currency_code?: string | null
          current_observation_provider?: string | null
          date_format?: string | null
          deleted_at?: string | null
          distance_unit?: string | null
          elevation_metres?: number | null
          forecast_provider?: string
          fuel_unit?: string | null
          id?: string
          irrigation_recent_rain_lookback_hours?: number
          latitude?: number | null
          logo_path?: string | null
          logo_updated_at?: string | null
          longitude?: number | null
          name: string
          owner_id?: string | null
          season_start_day?: number
          season_start_month?: number
          spray_carrier_volume_basis?: string | null
          spray_compliance_profile?: string | null
          spray_rate_area_unit?: string | null
          sugar_measurement_unit?: string | null
          terminology_region?: string | null
          timezone?: string | null
          updated_at?: string
          volume_unit?: string | null
          yield_samples_per_hectare?: number
        }
        Update: {
          area_unit?: string | null
          country?: string | null
          country_code?: string | null
          created_at?: string
          currency_code?: string | null
          current_observation_provider?: string | null
          date_format?: string | null
          deleted_at?: string | null
          distance_unit?: string | null
          elevation_metres?: number | null
          forecast_provider?: string
          fuel_unit?: string | null
          id?: string
          irrigation_recent_rain_lookback_hours?: number
          latitude?: number | null
          logo_path?: string | null
          logo_updated_at?: string | null
          longitude?: number | null
          name?: string
          owner_id?: string | null
          season_start_day?: number
          season_start_month?: number
          spray_carrier_volume_basis?: string | null
          spray_compliance_profile?: string | null
          spray_rate_area_unit?: string | null
          sugar_measurement_unit?: string | null
          terminology_region?: string | null
          timezone?: string | null
          updated_at?: string
          volume_unit?: string | null
          yield_samples_per_hectare?: number
        }
        Relationships: [
          {
            foreignKeyName: "vineyards_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      vintage_note_types: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          group_code: string
          id: string
          is_active: boolean
          is_system: boolean
          label: string
          sort_order: number
          updated_at: string
          updated_by: string | null
          vineyard_id: string | null
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          group_code: string
          id?: string
          is_active?: boolean
          is_system?: boolean
          label: string
          sort_order?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          group_code?: string
          id?: string
          is_active?: boolean
          is_system?: boolean
          label?: string
          sort_order?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "vintage_note_types_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vintage_notes: {
        Row: {
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          note_date: string
          note_type_id: string | null
          note_type_label: string | null
          notes: string | null
          observed_by_user_id: string | null
          observer_name_snapshot: string | null
          sync_version: number
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          vintage_year: number
        }
        Insert: {
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id: string
          note_date?: string
          note_type_id?: string | null
          note_type_label?: string | null
          notes?: string | null
          observed_by_user_id?: string | null
          observer_name_snapshot?: string | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
          vintage_year: number
        }
        Update: {
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          note_date?: string
          note_type_id?: string | null
          note_type_label?: string | null
          notes?: string | null
          observed_by_user_id?: string | null
          observer_name_snapshot?: string | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
          vintage_year?: number
        }
        Relationships: [
          {
            foreignKeyName: "vintage_notes_note_type_id_fkey"
            columns: ["note_type_id"]
            isOneToOne: false
            referencedRelation: "vintage_note_types"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vintage_notes_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vintage_report_diagnostics: {
        Row: {
          model: string | null
          operation_id: string
          output_contract: string
          provider_response_id: string | null
          provider_store: boolean
          updated_at: string
          usage: Json | null
          validated_content: Json | null
        }
        Insert: {
          model?: string | null
          operation_id: string
          output_contract: string
          provider_response_id?: string | null
          provider_store: boolean
          updated_at?: string
          usage?: Json | null
          validated_content?: Json | null
        }
        Update: {
          model?: string | null
          operation_id?: string
          output_contract?: string
          provider_response_id?: string | null
          provider_store?: boolean
          updated_at?: string
          usage?: Json | null
          validated_content?: Json | null
        }
        Relationships: [
          {
            foreignKeyName: "vintage_report_diagnostics_operation_id_fkey"
            columns: ["operation_id"]
            isOneToOne: true
            referencedRelation: "vintage_report_requests"
            referencedColumns: ["operation_id"]
          },
        ]
      }
      vintage_report_requests: {
        Row: {
          action: string
          authored_by: string
          created_at: string
          error_code: string | null
          evidence: Json
          expected_revision_id: string | null
          input: Json
          operation_id: string
          report_id: string
          report_through: string
          result_revision_id: string | null
          started_at: string | null
          status: string
          vineyard_id: string
        }
        Insert: {
          action: string
          authored_by: string
          created_at?: string
          error_code?: string | null
          evidence: Json
          expected_revision_id?: string | null
          input: Json
          operation_id: string
          report_id: string
          report_through: string
          result_revision_id?: string | null
          started_at?: string | null
          status?: string
          vineyard_id: string
        }
        Update: {
          action?: string
          authored_by?: string
          created_at?: string
          error_code?: string | null
          evidence?: Json
          expected_revision_id?: string | null
          input?: Json
          operation_id?: string
          report_id?: string
          report_through?: string
          result_revision_id?: string | null
          started_at?: string | null
          status?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vintage_report_requests_report_id_fkey"
            columns: ["report_id"]
            isOneToOne: false
            referencedRelation: "vintage_reports"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vintage_report_requests_result_revision_id_fkey"
            columns: ["result_revision_id"]
            isOneToOne: false
            referencedRelation: "vintage_report_revisions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vintage_report_requests_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vintage_report_revisions: {
        Row: {
          action: string
          collected_at: string
          content: Json
          created_at: string
          created_by: string
          evidence: Json
          id: string
          operation_id: string
          report_id: string
          report_through: string
          revision: number
          vineyard_id: string
        }
        Insert: {
          action: string
          collected_at: string
          content: Json
          created_at?: string
          created_by: string
          evidence: Json
          id?: string
          operation_id: string
          report_id: string
          report_through: string
          revision: number
          vineyard_id: string
        }
        Update: {
          action?: string
          collected_at?: string
          content?: Json
          created_at?: string
          created_by?: string
          evidence?: Json
          id?: string
          operation_id?: string
          report_id?: string
          report_through?: string
          revision?: number
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vintage_report_revisions_operation_id_fkey"
            columns: ["operation_id"]
            isOneToOne: true
            referencedRelation: "vintage_report_requests"
            referencedColumns: ["operation_id"]
          },
          {
            foreignKeyName: "vintage_report_revisions_report_id_fkey"
            columns: ["report_id"]
            isOneToOne: false
            referencedRelation: "vintage_reports"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vintage_report_revisions_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      vintage_reports: {
        Row: {
          current_revision_id: string | null
          id: string
          vineyard_id: string
          vintage: number
        }
        Insert: {
          current_revision_id?: string | null
          id?: string
          vineyard_id: string
          vintage: number
        }
        Update: {
          current_revision_id?: string | null
          id?: string
          vineyard_id?: string
          vintage?: number
        }
        Relationships: [
          {
            foreignKeyName: "vintage_reports_current_revision_id_fkey"
            columns: ["current_revision_id"]
            isOneToOne: false
            referencedRelation: "vintage_report_revisions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vintage_reports_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      webhook_deliveries: {
        Row: {
          attempt_count: number
          cancel_reason: string | null
          cancelled_at: string | null
          claim_token: string | null
          claimed_at: string | null
          created_at: string
          delivered_at: string | null
          endpoint_id: string
          event_id: string
          failed_at: string | null
          id: string
          integration_client_id: string
          is_test: boolean
          last_error_code: string | null
          last_status_code: number | null
          next_attempt_at: string
          public_id: string
          replay_of: string | null
          status: string
          subscription_id: string | null
          vineyard_id: string | null
        }
        Insert: {
          attempt_count?: number
          cancel_reason?: string | null
          cancelled_at?: string | null
          claim_token?: string | null
          claimed_at?: string | null
          created_at?: string
          delivered_at?: string | null
          endpoint_id: string
          event_id: string
          failed_at?: string | null
          id?: string
          integration_client_id: string
          is_test?: boolean
          last_error_code?: string | null
          last_status_code?: number | null
          next_attempt_at?: string
          public_id?: string
          replay_of?: string | null
          status?: string
          subscription_id?: string | null
          vineyard_id?: string | null
        }
        Update: {
          attempt_count?: number
          cancel_reason?: string | null
          cancelled_at?: string | null
          claim_token?: string | null
          claimed_at?: string | null
          created_at?: string
          delivered_at?: string | null
          endpoint_id?: string
          event_id?: string
          failed_at?: string | null
          id?: string
          integration_client_id?: string
          is_test?: boolean
          last_error_code?: string | null
          last_status_code?: number | null
          next_attempt_at?: string
          public_id?: string
          replay_of?: string | null
          status?: string
          subscription_id?: string | null
          vineyard_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "webhook_deliveries_endpoint_id_fkey"
            columns: ["endpoint_id"]
            isOneToOne: false
            referencedRelation: "webhook_endpoints"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "webhook_deliveries_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "integration_events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "webhook_deliveries_integration_client_id_fkey"
            columns: ["integration_client_id"]
            isOneToOne: false
            referencedRelation: "integration_clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "webhook_deliveries_replay_of_fkey"
            columns: ["replay_of"]
            isOneToOne: false
            referencedRelation: "webhook_deliveries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "webhook_deliveries_subscription_id_fkey"
            columns: ["subscription_id"]
            isOneToOne: false
            referencedRelation: "webhook_subscriptions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "webhook_deliveries_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      webhook_delivery_attempts: {
        Row: {
          attempt_number: number
          attempted_at: string
          delivery_id: string
          duration_ms: number | null
          error_category: string | null
          error_detail: string | null
          finished_at: string | null
          http_status: number | null
          id: string
        }
        Insert: {
          attempt_number: number
          attempted_at?: string
          delivery_id: string
          duration_ms?: number | null
          error_category?: string | null
          error_detail?: string | null
          finished_at?: string | null
          http_status?: number | null
          id?: string
        }
        Update: {
          attempt_number?: number
          attempted_at?: string
          delivery_id?: string
          duration_ms?: number | null
          error_category?: string | null
          error_detail?: string | null
          finished_at?: string | null
          http_status?: number | null
          id?: string
        }
        Relationships: [
          {
            foreignKeyName: "webhook_delivery_attempts_delivery_id_fkey"
            columns: ["delivery_id"]
            isOneToOne: false
            referencedRelation: "webhook_deliveries"
            referencedColumns: ["id"]
          },
        ]
      }
      webhook_endpoints: {
        Row: {
          consecutive_failures: number
          created_at: string
          created_by: string
          deleted_at: string | null
          disabled_at: string | null
          disabled_reason: string | null
          id: string
          integration_client_id: string
          last_failure_at: string | null
          last_success_at: string | null
          name: string | null
          paused_at: string | null
          secret_ref: string | null
          signing_secret_hash: string
          signing_secret_prefix: string
          status: string
          updated_at: string
          url: string
        }
        Insert: {
          consecutive_failures?: number
          created_at?: string
          created_by: string
          deleted_at?: string | null
          disabled_at?: string | null
          disabled_reason?: string | null
          id?: string
          integration_client_id: string
          last_failure_at?: string | null
          last_success_at?: string | null
          name?: string | null
          paused_at?: string | null
          secret_ref?: string | null
          signing_secret_hash: string
          signing_secret_prefix: string
          status?: string
          updated_at?: string
          url: string
        }
        Update: {
          consecutive_failures?: number
          created_at?: string
          created_by?: string
          deleted_at?: string | null
          disabled_at?: string | null
          disabled_reason?: string | null
          id?: string
          integration_client_id?: string
          last_failure_at?: string | null
          last_success_at?: string | null
          name?: string | null
          paused_at?: string | null
          secret_ref?: string | null
          signing_secret_hash?: string
          signing_secret_prefix?: string
          status?: string
          updated_at?: string
          url?: string
        }
        Relationships: [
          {
            foreignKeyName: "webhook_endpoints_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "webhook_endpoints_integration_client_id_fkey"
            columns: ["integration_client_id"]
            isOneToOne: false
            referencedRelation: "integration_clients"
            referencedColumns: ["id"]
          },
        ]
      }
      webhook_subscriptions: {
        Row: {
          created_at: string
          event_type: string
          id: string
          is_active: boolean
          vineyard_id: string | null
          webhook_endpoint_id: string
        }
        Insert: {
          created_at?: string
          event_type: string
          id?: string
          is_active?: boolean
          vineyard_id?: string | null
          webhook_endpoint_id: string
        }
        Update: {
          created_at?: string
          event_type?: string
          id?: string
          is_active?: boolean
          vineyard_id?: string | null
          webhook_endpoint_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "webhook_subscriptions_event_type_fkey"
            columns: ["event_type"]
            isOneToOne: false
            referencedRelation: "integration_webhook_event_catalog"
            referencedColumns: ["event"]
          },
          {
            foreignKeyName: "webhook_subscriptions_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "webhook_subscriptions_webhook_endpoint_id_fkey"
            columns: ["webhook_endpoint_id"]
            isOneToOne: false
            referencedRelation: "webhook_endpoints"
            referencedColumns: ["id"]
          },
        ]
      }
      website_cta_clicks: {
        Row: {
          created_at: string
          environment: string
          id: string
          page_path: string
          session_id: string
          target: string
        }
        Insert: {
          created_at?: string
          environment?: string
          id?: string
          page_path: string
          session_id: string
          target: string
        }
        Update: {
          created_at?: string
          environment?: string
          id?: string
          page_path?: string
          session_id?: string
          target?: string
        }
        Relationships: []
      }
      website_page_views: {
        Row: {
          created_at: string
          environment: string
          id: string
          page_path: string
          referrer_domain: string | null
          session_id: string
          utm_campaign: string | null
          utm_medium: string | null
          utm_source: string | null
        }
        Insert: {
          created_at?: string
          environment?: string
          id?: string
          page_path: string
          referrer_domain?: string | null
          session_id: string
          utm_campaign?: string | null
          utm_medium?: string | null
          utm_source?: string | null
        }
        Update: {
          created_at?: string
          environment?: string
          id?: string
          page_path?: string
          referrer_domain?: string | null
          session_id?: string
          utm_campaign?: string | null
          utm_medium?: string | null
          utm_source?: string | null
        }
        Relationships: []
      }
      work_task_labour_lines: {
        Row: {
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          hourly_rate: number | null
          hours_per_worker: number
          id: string
          notes: string
          sync_version: number
          total_cost: number | null
          total_hours: number | null
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          work_date: string
          work_task_id: string
          worker_count: number
          worker_type: string
          worker_type_id: string | null
        }
        Insert: {
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          hourly_rate?: number | null
          hours_per_worker?: number
          id?: string
          notes?: string
          sync_version?: number
          total_cost?: number | null
          total_hours?: number | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
          work_date: string
          work_task_id: string
          worker_count?: number
          worker_type?: string
          worker_type_id?: string | null
        }
        Update: {
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          hourly_rate?: number | null
          hours_per_worker?: number
          id?: string
          notes?: string
          sync_version?: number
          total_cost?: number | null
          total_hours?: number | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
          work_date?: string
          work_task_id?: string
          worker_count?: number
          worker_type?: string
          worker_type_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "work_task_labour_lines_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "work_task_labour_lines_work_task_id_fkey"
            columns: ["work_task_id"]
            isOneToOne: false
            referencedRelation: "v_work_task_effective_labour_cost"
            referencedColumns: ["work_task_id"]
          },
          {
            foreignKeyName: "work_task_labour_lines_work_task_id_fkey"
            columns: ["work_task_id"]
            isOneToOne: false
            referencedRelation: "work_tasks"
            referencedColumns: ["id"]
          },
        ]
      }
      work_task_machine_lines: {
        Row: {
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          duration_hours: number | null
          end_engine_hours: number | null
          end_time: string | null
          engine_hours_used: number | null
          entry_source: string
          equipment_name_snapshot: string
          equipment_ref_id: string | null
          equipment_source: string | null
          fuel_cost: number | null
          fuel_litres: number | null
          hourly_machine_rate: number | null
          id: string
          notes: string
          operator_user_id: string | null
          start_engine_hours: number | null
          start_time: string | null
          sync_version: number
          total_machine_cost: number | null
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          work_date: string
          work_task_id: string
          worker_type_id: string | null
        }
        Insert: {
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          duration_hours?: number | null
          end_engine_hours?: number | null
          end_time?: string | null
          engine_hours_used?: number | null
          entry_source?: string
          equipment_name_snapshot?: string
          equipment_ref_id?: string | null
          equipment_source?: string | null
          fuel_cost?: number | null
          fuel_litres?: number | null
          hourly_machine_rate?: number | null
          id?: string
          notes?: string
          operator_user_id?: string | null
          start_engine_hours?: number | null
          start_time?: string | null
          sync_version?: number
          total_machine_cost?: number | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
          work_date: string
          work_task_id: string
          worker_type_id?: string | null
        }
        Update: {
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          duration_hours?: number | null
          end_engine_hours?: number | null
          end_time?: string | null
          engine_hours_used?: number | null
          entry_source?: string
          equipment_name_snapshot?: string
          equipment_ref_id?: string | null
          equipment_source?: string | null
          fuel_cost?: number | null
          fuel_litres?: number | null
          hourly_machine_rate?: number | null
          id?: string
          notes?: string
          operator_user_id?: string | null
          start_engine_hours?: number | null
          start_time?: string | null
          sync_version?: number
          total_machine_cost?: number | null
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
          work_date?: string
          work_task_id?: string
          worker_type_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "work_task_machine_lines_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "work_task_machine_lines_work_task_id_fkey"
            columns: ["work_task_id"]
            isOneToOne: false
            referencedRelation: "v_work_task_effective_labour_cost"
            referencedColumns: ["work_task_id"]
          },
          {
            foreignKeyName: "work_task_machine_lines_work_task_id_fkey"
            columns: ["work_task_id"]
            isOneToOne: false
            referencedRelation: "work_tasks"
            referencedColumns: ["id"]
          },
        ]
      }
      work_task_materials: {
        Row: {
          base_material_id: string | null
          category: string
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          material_name: string
          notes: string
          quantity: number
          sync_version: number
          total_cost: number | null
          unit: string
          unit_cost: number
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          vineyard_material_id: string | null
          work_task_id: string
        }
        Insert: {
          base_material_id?: string | null
          category?: string
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          material_name: string
          notes?: string
          quantity?: number
          sync_version?: number
          total_cost?: number | null
          unit: string
          unit_cost?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
          vineyard_material_id?: string | null
          work_task_id: string
        }
        Update: {
          base_material_id?: string | null
          category?: string
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          material_name?: string
          notes?: string
          quantity?: number
          sync_version?: number
          total_cost?: number | null
          unit?: string
          unit_cost?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
          vineyard_material_id?: string | null
          work_task_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "work_task_materials_base_material_id_fkey"
            columns: ["base_material_id"]
            isOneToOne: false
            referencedRelation: "material_catalogue"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "work_task_materials_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "work_task_materials_vineyard_material_id_fkey"
            columns: ["vineyard_material_id"]
            isOneToOne: false
            referencedRelation: "vineyard_materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "work_task_materials_work_task_id_fkey"
            columns: ["work_task_id"]
            isOneToOne: false
            referencedRelation: "v_work_task_effective_labour_cost"
            referencedColumns: ["work_task_id"]
          },
          {
            foreignKeyName: "work_task_materials_work_task_id_fkey"
            columns: ["work_task_id"]
            isOneToOne: false
            referencedRelation: "work_tasks"
            referencedColumns: ["id"]
          },
        ]
      }
      work_task_paddocks: {
        Row: {
          area_ha: number | null
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          paddock_id: string
          sync_version: number
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          work_task_id: string
        }
        Insert: {
          area_ha?: number | null
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          paddock_id: string
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
          work_task_id: string
        }
        Update: {
          area_ha?: number | null
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          paddock_id?: string
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
          work_task_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "work_task_paddocks_paddock_id_fkey"
            columns: ["paddock_id"]
            isOneToOne: false
            referencedRelation: "paddocks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "work_task_paddocks_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "work_task_paddocks_work_task_id_fkey"
            columns: ["work_task_id"]
            isOneToOne: false
            referencedRelation: "v_work_task_effective_labour_cost"
            referencedColumns: ["work_task_id"]
          },
          {
            foreignKeyName: "work_task_paddocks_work_task_id_fkey"
            columns: ["work_task_id"]
            isOneToOne: false
            referencedRelation: "work_tasks"
            referencedColumns: ["id"]
          },
        ]
      }
      work_task_piece_rate_rows: {
        Row: {
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          paddock_id: string
          paddock_row_id: string | null
          row_number: number | null
          sync_version: number
          updated_at: string
          updated_by: string | null
          vine_count: number
          vineyard_id: string
          work_task_id: string
        }
        Insert: {
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          paddock_id: string
          paddock_row_id?: string | null
          row_number?: number | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vine_count?: number
          vineyard_id: string
          work_task_id: string
        }
        Update: {
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          paddock_id?: string
          paddock_row_id?: string | null
          row_number?: number | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vine_count?: number
          vineyard_id?: string
          work_task_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "work_task_piece_rate_rows_paddock_id_fkey"
            columns: ["paddock_id"]
            isOneToOne: false
            referencedRelation: "paddocks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "work_task_piece_rate_rows_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "work_task_piece_rate_rows_work_task_id_fkey"
            columns: ["work_task_id"]
            isOneToOne: false
            referencedRelation: "v_work_task_effective_labour_cost"
            referencedColumns: ["work_task_id"]
          },
          {
            foreignKeyName: "work_task_piece_rate_rows_work_task_id_fkey"
            columns: ["work_task_id"]
            isOneToOne: false
            referencedRelation: "work_tasks"
            referencedColumns: ["id"]
          },
        ]
      }
      work_task_types: {
        Row: {
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          is_default: boolean
          name: string
          sort_order: number
          sync_version: number
          updated_at: string
          updated_by: string | null
          vineyard_id: string
        }
        Insert: {
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_default?: boolean
          name: string
          sort_order?: number
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
        }
        Update: {
          client_updated_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_default?: boolean
          name?: string
          sort_order?: number
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "work_task_types_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      work_tasks: {
        Row: {
          archived_at: string | null
          archived_by: string | null
          area_ha: number | null
          assigned_external_resource_id: string | null
          assigned_to: string | null
          client_updated_at: string | null
          completed_at: string | null
          completed_by: string | null
          costing_method: string
          created_at: string
          created_by: string | null
          date: string
          deleted_at: string | null
          description: string | null
          duration_hours: number
          end_date: string | null
          external_id: string | null
          finalized_at: string | null
          finalized_by: string | null
          id: string
          integration_api_key_id: string | null
          integration_client_id: string | null
          is_archived: boolean
          is_finalized: boolean
          notes: string
          origin: string
          paddock_id: string | null
          paddock_name: string
          piece_rate_per_vine: number | null
          piece_rate_total_cost: number | null
          piece_vine_count: number | null
          pruning_activity_id: string | null
          resources: Json | null
          schedule_basis: string
          start_date: string | null
          status: string | null
          sync_version: number
          target_el_stage: number | null
          task_type: string
          updated_at: string
          updated_by: string | null
          updated_by_integration_client_id: string | null
          vineyard_id: string
          vintage_year: number | null
        }
        Insert: {
          archived_at?: string | null
          archived_by?: string | null
          area_ha?: number | null
          assigned_external_resource_id?: string | null
          assigned_to?: string | null
          client_updated_at?: string | null
          completed_at?: string | null
          completed_by?: string | null
          costing_method?: string
          created_at?: string
          created_by?: string | null
          date?: string
          deleted_at?: string | null
          description?: string | null
          duration_hours?: number
          end_date?: string | null
          external_id?: string | null
          finalized_at?: string | null
          finalized_by?: string | null
          id?: string
          integration_api_key_id?: string | null
          integration_client_id?: string | null
          is_archived?: boolean
          is_finalized?: boolean
          notes?: string
          origin?: string
          paddock_id?: string | null
          paddock_name?: string
          piece_rate_per_vine?: number | null
          piece_rate_total_cost?: number | null
          piece_vine_count?: number | null
          pruning_activity_id?: string | null
          resources?: Json | null
          schedule_basis?: string
          start_date?: string | null
          status?: string | null
          sync_version?: number
          target_el_stage?: number | null
          task_type?: string
          updated_at?: string
          updated_by?: string | null
          updated_by_integration_client_id?: string | null
          vineyard_id: string
          vintage_year?: number | null
        }
        Update: {
          archived_at?: string | null
          archived_by?: string | null
          area_ha?: number | null
          assigned_external_resource_id?: string | null
          assigned_to?: string | null
          client_updated_at?: string | null
          completed_at?: string | null
          completed_by?: string | null
          costing_method?: string
          created_at?: string
          created_by?: string | null
          date?: string
          deleted_at?: string | null
          description?: string | null
          duration_hours?: number
          end_date?: string | null
          external_id?: string | null
          finalized_at?: string | null
          finalized_by?: string | null
          id?: string
          integration_api_key_id?: string | null
          integration_client_id?: string | null
          is_archived?: boolean
          is_finalized?: boolean
          notes?: string
          origin?: string
          paddock_id?: string | null
          paddock_name?: string
          piece_rate_per_vine?: number | null
          piece_rate_total_cost?: number | null
          piece_vine_count?: number | null
          pruning_activity_id?: string | null
          resources?: Json | null
          schedule_basis?: string
          start_date?: string | null
          status?: string | null
          sync_version?: number
          target_el_stage?: number | null
          task_type?: string
          updated_at?: string
          updated_by?: string | null
          updated_by_integration_client_id?: string | null
          vineyard_id?: string
          vintage_year?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "work_tasks_assigned_external_resource_id_fkey"
            columns: ["assigned_external_resource_id"]
            isOneToOne: false
            referencedRelation: "vineyard_external_resources"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "work_tasks_assigned_to_fkey"
            columns: ["assigned_to"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "work_tasks_completed_by_fkey"
            columns: ["completed_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "work_tasks_integration_api_key_id_fkey"
            columns: ["integration_api_key_id"]
            isOneToOne: false
            referencedRelation: "integration_api_keys"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "work_tasks_integration_client_id_fkey"
            columns: ["integration_client_id"]
            isOneToOne: false
            referencedRelation: "integration_clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "work_tasks_updated_by_integration_client_id_fkey"
            columns: ["updated_by_integration_client_id"]
            isOneToOne: false
            referencedRelation: "integration_clients"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "work_tasks_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      worker_types: {
        Row: {
          client_updated_at: string | null
          cost_per_hour: number
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          name: string
          sync_version: number
          updated_at: string
          updated_by: string | null
          vineyard_id: string
        }
        Insert: {
          client_updated_at?: string | null
          cost_per_hour?: number
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          name?: string
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
        }
        Update: {
          client_updated_at?: string | null
          cost_per_hour?: number
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          name?: string
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "operator_categories_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      yield_bunch_weights: {
        Row: {
          base_revision: number | null
          bunch_weight_grams: number
          client_updated_at: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          paddock_id: string | null
          server_revision: number
          sync_version: number
          updated_at: string
          updated_by: string | null
          variety_key: string
          variety_name: string
          vineyard_id: string
        }
        Insert: {
          base_revision?: number | null
          bunch_weight_grams: number
          client_updated_at?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          paddock_id?: string | null
          server_revision?: number
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          variety_key: string
          variety_name: string
          vineyard_id: string
        }
        Update: {
          base_revision?: number | null
          bunch_weight_grams?: number
          client_updated_at?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          paddock_id?: string | null
          server_revision?: number
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          variety_key?: string
          variety_name?: string
          vineyard_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "yield_bunch_weights_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      yield_estimation_sessions: {
        Row: {
          client_updated_at: string | null
          completed_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          is_completed: boolean
          payload: Json
          session_created_at: string | null
          sync_version: number
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          vintage: number
        }
        Insert: {
          client_updated_at?: string | null
          completed_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_completed?: boolean
          payload: Json
          session_created_at?: string | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id: string
          vintage: number
        }
        Update: {
          client_updated_at?: string | null
          completed_at?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_completed?: boolean
          payload?: Json
          session_created_at?: string | null
          sync_version?: number
          updated_at?: string
          updated_by?: string | null
          vineyard_id?: string
          vintage?: number
        }
        Relationships: [
          {
            foreignKeyName: "yield_estimation_sessions_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      manual_issues_export: {
        Row: {
          along_row_distance_m: number | null
          assigned_user_id: string | null
          block_name: string | null
          category: string | null
          completed_at: string | null
          completed_by: string | null
          created_at: string | null
          created_by: string | null
          deleted_at: string | null
          description: string | null
          driving_row_number: number | null
          due_date: string | null
          effective_status: string | null
          issue_id: string | null
          latitude: number | null
          linked_work_task_id: string | null
          location_scope: string | null
          longitude: number | null
          paddock_id: string | null
          pin_row_number: number | null
          pin_side: string | null
          priority: string | null
          row_summary: string | null
          snapped_latitude: number | null
          snapped_longitude: number | null
          status: string | null
          title: string | null
          vineyard_id: string | null
          vineyard_name: string | null
        }
        Relationships: [
          {
            foreignKeyName: "pins_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      operator_categories: {
        Row: {
          client_updated_at: string | null
          cost_per_hour: number | null
          created_at: string | null
          created_by: string | null
          deleted_at: string | null
          id: string | null
          name: string | null
          sync_version: number | null
          updated_at: string | null
          updated_by: string | null
          vineyard_id: string | null
        }
        Insert: {
          client_updated_at?: string | null
          cost_per_hour?: number | null
          created_at?: string | null
          created_by?: string | null
          deleted_at?: string | null
          id?: string | null
          name?: string | null
          sync_version?: number | null
          updated_at?: string | null
          updated_by?: string | null
          vineyard_id?: string | null
        }
        Update: {
          client_updated_at?: string | null
          cost_per_hour?: number | null
          created_at?: string | null
          created_by?: string | null
          deleted_at?: string | null
          id?: string | null
          name?: string | null
          sync_version?: number | null
          updated_at?: string | null
          updated_by?: string | null
          vineyard_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "operator_categories_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      picking_yield_planting_totals: {
        Row: {
          actual_yield_tonnes: number | null
          clone: string | null
          first_picked_at: string | null
          last_picked_at: string | null
          member_allocation_ids: string[] | null
          paddock_id: string | null
          paddock_name: string | null
          pick_count: number | null
          planting_group_key: string | null
          rootstock: string | null
          total_grape_value: number | null
          total_weight_kg: number | null
          unlinked_variety_key: string | null
          variety_name: string | null
          vineyard_id: string | null
          vintage: number | null
        }
        Relationships: [
          {
            foreignKeyName: "picking_records_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      picking_yield_totals: {
        Row: {
          actual_yield_tonnes: number | null
          first_picked_at: string | null
          last_picked_at: string | null
          paddock_id: string | null
          paddock_name: string | null
          pick_count: number | null
          total_grape_value: number | null
          total_weight_kg: number | null
          variety_name: string | null
          vineyard_id: string | null
          vintage: number | null
        }
        Relationships: [
          {
            foreignKeyName: "picking_records_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      pin_placements: {
        Row: {
          along_row_distance_m: number | null
          deleted_at: string | null
          driving_row_number: number | null
          has_row_segments: boolean | null
          is_location_assigned: boolean | null
          latitude: number | null
          location_assignment_basis: string | null
          location_scope: string | null
          location_warning_code: string | null
          longitude: number | null
          mode: string | null
          paddock_id: string | null
          paddock_name: string | null
          pin_id: string | null
          pin_row_number: number | null
          pin_side: string | null
          row_summary: string | null
          segments: Json | null
          snapped_to_row: boolean | null
          stored_location_scope: string | null
          vineyard_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "pins_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      pins_export: {
        Row: {
          along_row_distance_m: number | null
          block_id: string | null
          block_name: string | null
          button_color: string | null
          category: string | null
          completed_at: string | null
          completed_by: string | null
          created_at: string | null
          created_by: string | null
          deleted_at: string | null
          driving_row_number: number | null
          growth_stage_code: string | null
          has_row_segments: boolean | null
          is_completed: boolean | null
          is_location_assigned: boolean | null
          latitude: number | null
          location_assignment_basis: string | null
          location_scope: string | null
          location_warning_code: string | null
          longitude: number | null
          mode: string | null
          notes: string | null
          pin_id: string | null
          pin_row_number: number | null
          pin_side: string | null
          row_summary: string | null
          snapped_to_row: boolean | null
          status: string | null
          title: string | null
          vineyard_id: string | null
          vineyard_name: string | null
        }
        Relationships: [
          {
            foreignKeyName: "pins_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      pruning_activity_allocation_export: {
        Row: {
          activity_costing_method: string | null
          activity_date: string | null
          activity_hourly_rate: number | null
          activity_id: string | null
          activity_labour_cost: number | null
          activity_labour_cost_source: string | null
          activity_labour_hours: number | null
          activity_labour_line_count: number | null
          activity_piece_rate_per_vine: number | null
          activity_piece_vine_count: number | null
          allocation_id: string | null
          allocation_index: number | null
          allocation_share_labour_cost: number | null
          allocation_share_labour_hours_informational: number | null
          allocation_share_of_row_equivalents: number | null
          block: string | null
          block_summary: string | null
          completion_row_equivalents: number | null
          created_at: string | null
          created_by: string | null
          is_primary_allocation: boolean | null
          is_skipped: boolean | null
          labour_line_count: number | null
          method: string | null
          paddock_id: string | null
          pruned_row_equivalents: number | null
          pruning_season_id: string | null
          quarters: number | null
          row_equivalents: number | null
          rows: Json | null
          season_year: number | null
          skipped_row_equivalents: number | null
          status: string | null
          updated_at: string | null
          vines: number | null
          vines_pruned: number | null
          vines_skipped: number | null
          vineyard_id: string | null
          vintage_year: number | null
          work_task_id: string | null
          worker_or_crew: string | null
        }
        Relationships: [
          {
            foreignKeyName: "pruning_activities_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pruning_entries_pruning_season_id_fkey"
            columns: ["pruning_season_id"]
            isOneToOne: false
            referencedRelation: "pruning_seasons"
            referencedColumns: ["id"]
          },
        ]
      }
      saved_chemical_intelligence_audit: {
        Row: {
          active_ingredient_count: number | null
          activity_group_count: number | null
          activity_group_scheme: string | null
          activity_group_table_version: number | null
          activity_groups: string[] | null
          conflict_count: number | null
          has_conflict: boolean | null
          has_structured_actives: boolean | null
          id: string | null
          intelligence_schema_version: number | null
          label_rate_bases: string[] | null
          legacy_active_ingredient: string | null
          legacy_chemical_group: string | null
          legacy_mixture_needs_match: boolean | null
          legacy_mode_of_action: string | null
          missing_activity_groups: boolean | null
          missing_registration: boolean | null
          name: string | null
          product_category: string | null
          registered_use_count: number | null
          registration_country: string | null
          registration_number: string | null
          registration_scheme: string | null
          resistance_classification_state: string | null
          resistance_unresolved: boolean | null
          unresolved_mixture: boolean | null
          verification_status: string | null
          verified_at: string | null
          vineyard_id: string | null
        }
        Insert: {
          active_ingredient_count?: never
          activity_group_count?: never
          activity_group_scheme?: string | null
          activity_group_table_version?: number | null
          activity_groups?: string[] | null
          conflict_count?: never
          has_conflict?: never
          has_structured_actives?: never
          id?: string | null
          intelligence_schema_version?: number | null
          label_rate_bases?: string[] | null
          legacy_active_ingredient?: string | null
          legacy_chemical_group?: string | null
          legacy_mixture_needs_match?: never
          legacy_mode_of_action?: string | null
          missing_activity_groups?: never
          missing_registration?: never
          name?: string | null
          product_category?: string | null
          registered_use_count?: never
          registration_country?: string | null
          registration_number?: string | null
          registration_scheme?: string | null
          resistance_classification_state?: string | null
          resistance_unresolved?: never
          unresolved_mixture?: never
          verification_status?: string | null
          verified_at?: string | null
          vineyard_id?: string | null
        }
        Update: {
          active_ingredient_count?: never
          activity_group_count?: never
          activity_group_scheme?: string | null
          activity_group_table_version?: number | null
          activity_groups?: string[] | null
          conflict_count?: never
          has_conflict?: never
          has_structured_actives?: never
          id?: string | null
          intelligence_schema_version?: number | null
          label_rate_bases?: string[] | null
          legacy_active_ingredient?: string | null
          legacy_chemical_group?: string | null
          legacy_mixture_needs_match?: never
          legacy_mode_of_action?: string | null
          missing_activity_groups?: never
          missing_registration?: never
          name?: string | null
          product_category?: string | null
          registered_use_count?: never
          registration_country?: string | null
          registration_number?: string | null
          registration_scheme?: string | null
          resistance_classification_state?: string | null
          resistance_unresolved?: never
          unresolved_mixture?: never
          verification_status?: string | null
          verified_at?: string | null
          vineyard_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "saved_chemicals_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      saved_chemical_intelligence_summary: {
        Row: {
          conflict_count: number | null
          legacy_mixture_count: number | null
          missing_groups_count: number | null
          missing_registration_count: number | null
          needs_match_count: number | null
          partially_verified_count: number | null
          structured_actives_count: number | null
          total_chemicals: number | null
          unresolved_mixture_count: number | null
          unverified_count: number | null
          verified_count: number | null
          vineyard_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "saved_chemicals_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      saved_chemicals_effective: {
        Row: {
          active_ingredient: string | null
          active_ingredients: Json | null
          activity_group_scheme: string | null
          activity_group_table_version: number | null
          activity_groups: string[] | null
          analysis_basis: string | null
          application_notes: string | null
          catalogue_snapshot_differs: boolean | null
          chemical_group: string | null
          chemical_v3_product_id: string | null
          chemical_v3_review_status_snapshot: string | null
          chemical_v3_revision_id: string | null
          client_updated_at: string | null
          created_at: string | null
          created_by: string | null
          crop: string | null
          default_rates: Json | null
          deleted_at: string | null
          density: number | null
          effective_catalogue_revision_id: string | null
          entry_source: string | null
          id: string | null
          intelligence_schema_version: number | null
          inventory_quantity: number | null
          inventory_unit: string | null
          is_active: boolean | null
          label_rate_bases: string[] | null
          label_reference: string | null
          label_url: string | null
          label_version: string | null
          manufacturer: string | null
          master_chemical_id: string | null
          master_source_revision: number | null
          mode_of_action: string | null
          name: string | null
          nitrogen_percent: number | null
          notes: string | null
          organic_certified: boolean | null
          pack_size: number | null
          pack_unit: string | null
          phosphorus_percent: number | null
          potassium_percent: number | null
          price_per_pack: number | null
          problem: string | null
          product_category: string | null
          product_form: string | null
          product_url: string | null
          purchase: Json | null
          rate_per_ha: number | null
          rates: Json | null
          registered_product_name: string | null
          registered_uses: Json | null
          registrant: string | null
          registration_country: string | null
          registration_number: string | null
          registration_scheme: string | null
          resistance_classification_state: string | null
          restrictions: string | null
          saved_catalogue_revision_id: string | null
          sync_version: number | null
          unit: string | null
          updated_at: string | null
          updated_by: string | null
          use: string | null
          verification_conflicts: Json | null
          verification_sources: Json | null
          verification_status: string | null
          verification_unresolved_fields: string[] | null
          verified_at: string | null
          vineyard_id: string | null
          vineyard_preferred_rate: Json | null
          vineyard_rate_override_evidence: Json | null
          vineyard_use_override_evidence: Json | null
        }
        Relationships: [
          {
            foreignKeyName: "saved_chemicals_v3_revision_fk"
            columns: ["saved_catalogue_revision_id"]
            isOneToOne: false
            referencedRelation: "chemical_v3_product_revisions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "saved_chemicals_v3_revision_fk"
            columns: ["saved_catalogue_revision_id"]
            isOneToOne: false
            referencedRelation: "saved_chemicals_effective"
            referencedColumns: ["effective_catalogue_revision_id"]
          },
        ]
      }
      v_growth_stage_observations: {
        Row: {
          created_at: string | null
          created_by: string | null
          id: string | null
          latitude: number | null
          longitude: number | null
          notes: string | null
          observed_at: string | null
          paddock_id: string | null
          photo_paths: string[] | null
          pin_id: string | null
          recorded_by_name: string | null
          row_number: number | null
          side: string | null
          source: string | null
          stage_code: string | null
          stage_label: string | null
          updated_at: string | null
          updated_by: string | null
          variety: string | null
          variety_id: string | null
          vineyard_id: string | null
        }
        Relationships: []
      }
      v_pin_attachment_preview: {
        Row: {
          button_name: string | null
          confidence: string | null
          current_latitude: number | null
          current_longitude: number | null
          heading: number | null
          legacy_row_number: number | null
          legacy_side: string | null
          mode: string | null
          paddock_id: string | null
          pin_id: string | null
          proposed_along_row_distance_m: number | null
          proposed_driving_row_number: number | null
          proposed_pin_row_number: number | null
          proposed_pin_side: string | null
          proposed_snapped_latitude: number | null
          proposed_snapped_longitude: number | null
          reason: string | null
          vineyard_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "pins_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
      v_work_task_effective_labour_cost: {
        Row: {
          cost_per_vine: number | null
          costing_method: string | null
          effective_labour_cost: number | null
          labour_cost_source: string | null
          labour_line_cost: number | null
          piece_rate_per_vine: number | null
          piece_rate_total_cost: number | null
          piece_vine_count: number | null
          pruning_line_cost: number | null
          vineyard_id: string | null
          work_task_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "work_tasks_vineyard_id_fkey"
            columns: ["vineyard_id"]
            isOneToOne: false
            referencedRelation: "vineyards"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Functions: {
      _account_trial_for: {
        Args: { p_user_id: string }
        Returns: {
          created_from: string
          is_active: boolean
          is_persisted: boolean
          status: string
          trial_ends_at: string
          trial_started_at: string
        }[]
      }
      _admin_application_block_ids: { Args: { p: Json }; Returns: Json }
      _admin_effective_access: {
        Args: { p_user_id: string }
        Returns: {
          billing_provider: string
          cancel_at_period_end: boolean
          current_period_end: string
          environment: string
          grace_period_end: string
          has_access: boolean
          is_owner: boolean
          licence_id: string
          manual_grant_expires_at: string
          manual_grant_reason: string
          plan_code: string
          plan_name: string
          plan_tier: string
          portal_access: boolean
          portal_access_level: string
          purchase_platform: string
          reason_code: string
          status: string
          subscription_id: string
          trial_end: string
          unlimited_licences: boolean
          vineyard_id: string
        }[]
      }
      _admin_integration_health: {
        Args: { p_client_id: string }
        Returns: Json
      }
      _admin_json_present: { Args: { v: Json }; Returns: boolean }
      _admin_mask_url: { Args: { p_url: string }; Returns: string }
      _admin_refresh_entitlement_state: {
        Args: { p_user_id: string }
        Returns: Json
      }
      _admin_tank_session_summary: { Args: { p: Json }; Returns: Json }
      _admin_trip_block_ids: { Args: { p: Json }; Returns: Json }
      _axisstream_exchange_claim_test: {
        Args: { p_vineyard_id: string }
        Returns: Json
      }
      _axisstream_exchange_get_token: {
        Args: { p_vineyard_id: string }
        Returns: string
      }
      _axisstream_require_system_admin_member: {
        Args: { p_vineyard_id: string }
        Returns: undefined
      }
      _billing_event_is_retryable: {
        Args: {
          e: Database["public"]["Tables"]["billing_provider_events"]["Row"]
        }
        Returns: boolean
      }
      _billing_grant_allowed_scopes: {
        Args: { p_grant_type: string }
        Returns: string[]
      }
      _billing_ms_to_ts: { Args: { p: string }; Returns: string }
      _billing_reprocess_provider_event: {
        Args: { p_admin: string; p_event_id: string }
        Returns: Json
      }
      _ensure_account_trial: { Args: { p_user_id: string }; Returns: undefined }
      _entitlement_enforcement_enabled: {
        Args: { p_has_internal_grant?: boolean; p_user_id: string }
        Returns: boolean
      }
      _fertigation_require_dev_access: {
        Args: { p_vineyard_id: string }
        Returns: undefined
      }
      _galcon_classify_comment: { Args: { p_comment: string }; Returns: string }
      _grape_clone_custom_key: {
        Args: { p_name: string; p_variety_key: string; p_vineyard_id: string }
        Returns: string
      }
      _grape_variety_custom_key: {
        Args: { p_name: string; p_vineyard_id: string }
        Returns: string
      }
      _grape_variety_slugify: { Args: { p_name: string }; Returns: string }
      _integration_api_date: { Args: { p: string }; Returns: string }
      _integration_api_el_stage_label: {
        Args: { p_code: string }
        Returns: string
      }
      _integration_api_fuel_record_json: {
        Args: { p_id: string }
        Returns: Json
      }
      _integration_api_grape_allocation_json: {
        Args: { p_id: string }
        Returns: Json
      }
      _integration_api_grape_purchaser_json: {
        Args: { p_id: string }
        Returns: Json
      }
      _integration_api_growth_stage_json: {
        Args: { p_id: string }
        Returns: Json
      }
      _integration_api_hash: { Args: { p: Json }; Returns: string }
      _integration_api_idem_begin: {
        Args: {
          p_client_id: string
          p_key: string
          p_operation: string
          p_request_hash: string
        }
        Returns: Json
      }
      _integration_api_idem_store: {
        Args: {
          p_reservation_id: string
          p_resource_id: string
          p_resource_type: string
          p_response: Json
          p_status: number
        }
        Returns: undefined
      }
      _integration_api_irrigation_json: {
        Args: { p_id: string }
        Returns: Json
      }
      _integration_api_ts: { Args: { p: string }; Returns: string }
      _integration_api_unknown_keys: {
        Args: { p_allowed: string[]; p_payload: Json }
        Returns: Json
      }
      _integration_api_uuid: { Args: { p: string }; Returns: string }
      _integration_api_work_task_json: { Args: { p_id: string }; Returns: Json }
      _integration_api_yield_blocks: {
        Args: { io_errors: Json; p_blocks: Json; p_vineyard_id: string }
        Returns: Record<string, unknown>
      }
      _integration_api_yield_record_json: {
        Args: { p_id: string }
        Returns: Json
      }
      _integration_audit: {
        Args: {
          p_action: string
          p_client_id: string
          p_metadata: Json
          p_vineyard_id: string
        }
        Returns: undefined
      }
      _integration_can_view: {
        Args: { p_client_id: string; p_user_id: string }
        Returns: boolean
      }
      _integration_client_has_scope: {
        Args: { p_client: string; p_scope: string }
        Returns: boolean
      }
      _integration_emit_event: {
        Args: {
          p_data: Json
          p_dedup_key: string
          p_event_type: string
          p_resource_id: string
          p_resource_type: string
          p_source: string
          p_vineyard_id: string
        }
        Returns: string
      }
      _integration_emit_safe: {
        Args: {
          p_data: Json
          p_dedup_key: string
          p_event_type: string
          p_resource_id: string
          p_resource_type: string
          p_source: string
          p_vineyard_id: string
        }
        Returns: undefined
      }
      _integration_event_scope: { Args: { p_event: string }; Returns: string }
      _integration_evt_provenance: {
        Args: { p_external_id: string; p_origin: string }
        Returns: Json
      }
      _integration_generate_secret: {
        Args: { p_environment: string }
        Returns: string
      }
      _integration_hash_secret: { Args: { p_secret: string }; Returns: string }
      _integration_is_vineyard_owner: {
        Args: { p_user_id: string; p_vineyard_id: string }
        Returns: boolean
      }
      _integration_require_manage: {
        Args: { p_client_id: string }
        Returns: {
          created_at: string
          created_by: string
          description: string | null
          id: string
          integration_type: string
          name: string
          owner_user_id: string
          paused_at: string | null
          revoked_at: string | null
          status: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "integration_clients"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _integration_validate_webhook_url: {
        Args: { p_url: string }
        Returns: undefined
      }
      _integration_webhook_endpoint_json: {
        Args: { r: Database["public"]["Tables"]["webhook_endpoints"]["Row"] }
        Returns: Json
      }
      _integration_webhook_require_endpoint: {
        Args: { p_endpoint_id: string }
        Returns: {
          consecutive_failures: number
          created_at: string
          created_by: string
          deleted_at: string | null
          disabled_at: string | null
          disabled_reason: string | null
          id: string
          integration_client_id: string
          last_failure_at: string | null
          last_success_at: string | null
          name: string | null
          paused_at: string | null
          secret_ref: string | null
          signing_secret_hash: string
          signing_secret_prefix: string
          status: string
          updated_at: string
          url: string
        }
        SetofOptions: {
          from: "*"
          to: "webhook_endpoints"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _integration_webhook_store_secret: {
        Args: { p_endpoint_id: string; p_secret: string }
        Returns: string
      }
      _integration_webhook_view_endpoint: {
        Args: { p_endpoint_id: string }
        Returns: {
          consecutive_failures: number
          created_at: string
          created_by: string
          deleted_at: string | null
          disabled_at: string | null
          disabled_reason: string | null
          id: string
          integration_client_id: string
          last_failure_at: string | null
          last_success_at: string | null
          name: string | null
          paused_at: string | null
          secret_ref: string | null
          signing_secret_hash: string
          signing_secret_prefix: string
          status: string
          updated_at: string
          url: string
        }
        SetofOptions: {
          from: "*"
          to: "webhook_endpoints"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _irrigation_allocate: {
        Args: { p_allocations: Json; p_total_volume_litres: number }
        Returns: Json
      }
      _irrigation_audit: {
        Args: {
          p_action: string
          p_entity_id: string
          p_entity_type: string
          p_new: Json
          p_old: Json
          p_vineyard_id: string
        }
        Returns: undefined
      }
      _irrigation_calc_label: { Args: { p_method: string }; Returns: string }
      _irrigation_compute: {
        Args: {
          p_calculation_method: string
          p_duration_minutes: number
          p_flow_litres_per_hour: number
          p_meter_finish_litres: number
          p_meter_start_litres: number
          p_total_volume_litres: number
          p_valve_id: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      _irrigation_data_quality: {
        Args: {
          p_area_missing: number
          p_efficiency_missing: number
          p_rainfall_complete: boolean
          p_total: number
          p_vines_missing: number
        }
        Returns: string
      }
      _irrigation_import_fingerprint: {
        Args: {
          p_comment: string
          p_controller_key: string
          p_date: string
          p_end_time: string
          p_flow_litres_per_hour: number
          p_program: string
          p_provider: string
          p_runtime_seconds: number
          p_start_time: string
          p_station_code: string
          p_valve_number: number
          p_vineyard_id: string
          p_water_litres: number
        }
        Returns: string
      }
      _irrigation_import_normalise_text: {
        Args: { p_text: string }
        Returns: string
      }
      _irrigation_import_num_text: {
        Args: { p_value: number }
        Returns: string
      }
      _irrigation_import_passes_threshold: {
        Args: {
          p_comparison: string
          p_threshold_litres: number
          p_water_litres: number
        }
        Returns: boolean
      }
      _irrigation_import_require_admin: {
        Args: { p_vineyard_id: string }
        Returns: undefined
      }
      _irrigation_local_today: {
        Args: { p_vineyard_id: string }
        Returns: string
      }
      _irrigation_measurement_group: {
        Args: { p_flow_estimated: boolean; p_method: string }
        Returns: string
      }
      _irrigation_measurement_label: {
        Args: { p_group: string }
        Returns: string
      }
      _irrigation_paddock_rows: {
        Args: { p_block_id?: string; p_vineyard_id: string }
        Returns: Json
      }
      _irrigation_pct_diff: {
        Args: { p_current: number; p_previous: number }
        Returns: number
      }
      _irrigation_period_report: {
        Args: {
          p_block_id: string
          p_calculation_method: string
          p_date_from: string
          p_date_to: string
          p_group_by: string
          p_include_estimated: boolean
          p_include_imported: boolean
          p_include_reversed: boolean
          p_include_zero_periods: boolean
          p_measurement_group: string
          p_report: string
          p_source_group: string
          p_source_type: string
          p_system_id: string
          p_valve_id: string
          p_variety_id: string
          p_vineyard_id: string
          p_vintage_year: number
          p_water_source: string
        }
        Returns: Json
      }
      _irrigation_period_rows: {
        Args: {
          p_block_id: string
          p_calculation_method: string
          p_date_from: string
          p_date_to: string
          p_from: string
          p_group_by: string
          p_include_estimated: boolean
          p_include_imported: boolean
          p_include_reversed: boolean
          p_include_zero_periods: boolean
          p_measurement_group: string
          p_source_group: string
          p_source_type: string
          p_system_id: string
          p_to: string
          p_valve_id: string
          p_variety_id: string
          p_vineyard_id: string
          p_vintage_year: number
          p_water_source: string
        }
        Returns: Json
      }
      _irrigation_rainfall_best: {
        Args: { p_from: string; p_to: string; p_vineyard_id: string }
        Returns: {
          day: string
          rainfall_mm: number
        }[]
      }
      _irrigation_rainfall_coverage: {
        Args: { p_from: string; p_to: string; p_vineyard_id: string }
        Returns: {
          coverage_end: string
          coverage_start: string
          data_complete: boolean
          expected_days: number
          future_days: number
          missing_days: number
          observed_days: number
        }[]
      }
      _irrigation_rainfall_warnings: {
        Args: { p_from: string; p_to: string; p_vineyard_id: string }
        Returns: Json
      }
      _irrigation_reconcile_counts: {
        Args: { p_total: number; p_weights: Json }
        Returns: Json
      }
      _irrigation_report_blocks: {
        Args: {
          p_block_id?: string
          p_calculation_method?: string
          p_date_from?: string
          p_date_to?: string
          p_include_estimated?: boolean
          p_include_imported?: boolean
          p_include_reversed?: boolean
          p_measurement_group?: string
          p_source_group?: string
          p_source_type?: string
          p_system_id?: string
          p_valve_id?: string
          p_variety_id?: string
          p_vineyard_id: string
          p_vintage_year?: number
          p_water_source?: string
        }
        Returns: {
          allocated_litres: number
          block_id: string
          calculation_method: string
          duration_minutes: number
          effective_litres: number
          measurement_group: string
          serviced_area_m2: number
          serviced_vine_count: number
          session_date: string
          session_id: string
          source_group: string
          source_type: string
          valve_id: string
          variety_id: string
          variety_name: string
          vintage_year: number
        }[]
      }
      _irrigation_report_envelope: {
        Args: {
          p_filters: Json
          p_payload: Json
          p_period_end: string
          p_period_start: string
          p_report: string
          p_vineyard_id: string
          p_vintage_year: number
        }
        Returns: Json
      }
      _irrigation_report_sessions: {
        Args: {
          p_block_id?: string
          p_calculation_method?: string
          p_date_from?: string
          p_date_to?: string
          p_include_estimated?: boolean
          p_include_imported?: boolean
          p_include_reversed?: boolean
          p_measurement_group?: string
          p_source_group?: string
          p_source_type?: string
          p_system_id?: string
          p_valve_id?: string
          p_variety_id?: string
          p_vineyard_id: string
          p_vintage_year?: number
          p_water_source?: string
        }
        Returns: {
          calculation_method: string
          created_at: string
          duration_minutes: number
          effective_litres: number
          measurement_group: string
          session_date: string
          session_id: string
          source_group: string
          source_type: string
          system_id: string
          system_name: string
          total_litres: number
          valve_id: string
          vintage_year: number
          water_source: string
        }[]
      }
      _irrigation_report_stats: {
        Args: {
          p_block_id?: string
          p_calculation_method?: string
          p_date_from?: string
          p_date_to?: string
          p_include_estimated?: boolean
          p_include_imported?: boolean
          p_include_reversed?: boolean
          p_measurement_group?: string
          p_source_group?: string
          p_source_type?: string
          p_system_id?: string
          p_valve_id?: string
          p_variety_id?: string
          p_vineyard_id: string
          p_vintage_year?: number
          p_water_source?: string
        }
        Returns: {
          blocks_missing_variety: number
          sessions_estimated: number
          sessions_missing_area: number
          sessions_missing_efficiency: number
          sessions_missing_vines: number
          sessions_without_allocation: number
          total_sessions: number
        }[]
      }
      _irrigation_report_timezone: {
        Args: { p_vineyard_id: string }
        Returns: string
      }
      _irrigation_report_unit_context: { Args: never; Returns: Json }
      _irrigation_require_access: {
        Args: { p_vineyard_id: string }
        Returns: undefined
      }
      _irrigation_resolve_flow: {
        Args: {
          p_blocks: Json
          p_configured_flow_lph: number
          p_measured_flow_lph: number
        }
        Returns: Json
      }
      _irrigation_resolve_valve_flow: {
        Args: { p_valve_id: string }
        Returns: Json
      }
      _irrigation_rows_weighting: { Args: { p_rows: Json }; Returns: Json }
      _irrigation_safe_season_date: {
        Args: { p_day: number; p_month: number; p_year: number }
        Returns: string
      }
      _irrigation_session_json: { Args: { p_id: string }; Returns: Json }
      _irrigation_source_group: {
        Args: { p_source_type: string }
        Returns: string
      }
      _irrigation_source_label: {
        Args: { p_source_type: string }
        Returns: string
      }
      _irrigation_spacing_estimate:
        | {
            Args: { p_length_metres: number; p_spacing_metres: number }
            Returns: number
          }
        | {
            Args: { p_length_metres: number; p_spacing_metres: number }
            Returns: number
          }
        | {
            Args: { p_length_metres: number; p_spacing_metres: number }
            Returns: number
          }
        | {
            Args: { p_length_metres: number; p_spacing_metres: number }
            Returns: number
          }
      _irrigation_stack_capability: {
        Args: { p_default: string }
        Returns: string
      }
      _irrigation_validate_session_times: {
        Args: {
          p_duration_minutes: number
          p_finished_at: string
          p_started_at: string
        }
        Returns: undefined
      }
      _irrigation_valve_allocations: {
        Args: { p_valve_id: string }
        Returns: Json
      }
      _irrigation_vintage_period: {
        Args: { p_vineyard_id: string; p_vintage_year: number }
        Returns: {
          period_end: string
          period_start: string
        }[]
      }
      _irrigation_warnings_from_stats: {
        Args: {
          p_area: number
          p_efficiency: number
          p_estimated: number
          p_no_alloc: number
          p_total: number
          p_variety_blocks: number
          p_vines: number
        }
        Returns: Json
      }
      _is_active_vineyard_owner: {
        Args: { p_user: string; p_vineyard: string }
        Returns: boolean
      }
      _mait_intelliweb_service_credentials: {
        Args: { p_vineyard_id: string }
        Returns: {
          network_id: string
          network_name: string
          password: string
          timezone: string
          username: string
        }[]
      }
      _mait_refresh_weather_capabilities: {
        Args: { p_module_id: string; p_vineyard_id: string }
        Returns: undefined
      }
      _mait_require_admin_member: {
        Args: { p_vineyard_id: string }
        Returns: undefined
      }
      _manual_issue_can_edit: {
        Args: { p_pin: Database["public"]["Tables"]["pins"]["Row"] }
        Returns: boolean
      }
      _manual_issue_parse_segments: {
        Args: { p_segments: Json }
        Returns: {
          row_number: number
          segment_number: number
        }[]
      }
      _manual_issue_user_name: {
        Args: { p_user_id: string; p_vineyard_id: string }
        Returns: string
      }
      _manual_issue_validate: {
        Args: {
          p_assigned_user_id: string
          p_category: string
          p_latitude: number
          p_location_scope: string
          p_longitude: number
          p_paddock_id: string
          p_priority: string
          p_segments: Json
          p_title: string
          p_vineyard_id: string
        }
        Returns: undefined
      }
      _normalise_operational_tool_ids: {
        Args: { p_ids: string[] }
        Returns: string[]
      }
      _paddock_polygon_area_hectares: {
        Args: { p_points: Json }
        Returns: number
      }
      _pin_attached_vine_row: {
        Args: {
          p_heading: number
          p_lower_number: number
          p_rows: Json
          p_side: string
          p_snapped_lat: number
          p_snapped_lon: number
        }
        Returns: number
      }
      _pin_bearing_degrees: {
        Args: { a_lat: number; a_lon: number; b_lat: number; b_lon: number }
        Returns: number
      }
      _pin_midpoint: {
        Args: { a_lat: number; a_lon: number; b_lat: number; b_lon: number }
        Returns: Record<string, unknown>
      }
      _pin_nearest_row_number: {
        Args: {
          p_centroid_lat: number
          p_lat: number
          p_lon: number
          p_rows: Json
        }
        Returns: number
      }
      _pin_point_in_polygon: {
        Args: { p_lat: number; p_lon: number; p_polygon: Json }
        Returns: boolean
      }
      _pin_signed_angular_diff: {
        Args: { a: number; b: number }
        Returns: number
      }
      _pin_snap_to_path: {
        Args: {
          p_lat: number
          p_lon: number
          p_lower_number: number
          p_rows: Json
        }
        Returns: Record<string, unknown>
      }
      _plan_funds_vineyard: {
        Args: {
          p_billing_provider: string
          p_plan_code: string
          p_plan_tier: string
        }
        Returns: boolean
      }
      _pruning_block_estimate: {
        Args: { p_paddock_id: string; p_vineyard_id: string }
        Returns: Json
      }
      _refresh_pruning_yield_estimates: {
        Args: { p_vineyard_id: string; p_vintage: number }
        Returns: Json
      }
      _refresh_vineyard_member_entitlements: {
        Args: { p_vineyard_id: string }
        Returns: number
      }
      _sanitise_client_text: {
        Args: { p_max?: number; p_value: string }
        Returns: string
      }
      _season_alloc_number: {
        Args: { p_elem: Json; p_keys: string[] }
        Returns: number
      }
      _season_alloc_text: {
        Args: { p_elem: Json; p_keys: string[] }
        Returns: string
      }
      _user_level_access: {
        Args: { p_user_id: string }
        Returns: {
          billing_provider: string
          cancel_at_period_end: boolean
          current_period_end: string
          environment: string
          grace_period_end: string
          has_access: boolean
          is_owner: boolean
          licence_id: string
          manual_grant_expires_at: string
          manual_grant_reason: string
          plan_code: string
          plan_name: string
          plan_tier: string
          portal_access: boolean
          portal_access_level: string
          purchase_platform: string
          reason_code: string
          status: string
          subscription_id: string
          trial_end: string
          unlimited_licences: boolean
          vineyard_id: string
        }[]
      }
      _variety_canonical: { Args: { p_name: string }; Returns: string }
      _variety_catalog_keys: {
        Args: never
        Returns: {
          display_name: string
          key: string
        }[]
      }
      _variety_catalog_match: {
        Args: { p_name: string }
        Returns: {
          display_name: string
          key: string
          optimal_gdd: number
        }[]
      }
      _variety_deterministic_id: {
        Args: { p_key: string; p_vineyard_id: string }
        Returns: string
      }
      _variety_is_known_deterministic_id: {
        Args: { p_variety_id: string; p_vineyard_id: string }
        Returns: boolean
      }
      _variety_key_from_id: {
        Args: { p_variety_id: string; p_vineyard_id: string }
        Returns: string
      }
      _vinetrack_subscription_is_current: {
        Args: {
          p_at?: string
          p_subscription: Database["public"]["Tables"]["vinetrack_subscriptions"]["Row"]
        }
        Returns: boolean
      }
      _vineyard_billing_subscription_id: {
        Args: { p_vineyard: string }
        Returns: string
      }
      _vineyard_entitlement_for: {
        Args: { p_vineyard_id: string }
        Returns: {
          access_source: string
          billing_owner_user_id: string
          expires_at: string
          has_entitlement: boolean
          is_trial: boolean
          is_vineyard_wide: boolean
          plan_code: string
          plan_name: string
          plan_tier: string
          reason_code: string
          starts_at: string
          subscription_id: string
          subscription_status: string
        }[]
      }
      _vineyard_owner_ids: {
        Args: { p_vineyard_id: string }
        Returns: {
          owner_uid: string
        }[]
      }
      _vr_collect: {
        Args: { p_through: string; p_vineyard: string; p_vintage: number }
        Returns: Json
      }
      _yield_master_block_bunch_weight: {
        Args: { p_paddock_id: string; p_vineyard_id: string }
        Returns: Json
      }
      _yield_row_effective_vine_count: {
        Args: { p_polygon: Json; p_rows: Json; p_spacing: number }
        Returns: number
      }
      accept_invitation: {
        Args: { p_invitation_id: string }
        Returns: undefined
      }
      account_deletion_preflight: { Args: never; Returns: Json }
      activate_trip_occurrences_v1: {
        Args: {
          p_expected_plan_revision: number
          p_expected_revision: number
          p_operation_id: string
          p_start: Json
          p_trip_id: string
        }
        Returns: Json
      }
      add_system_admin: {
        Args: { p_email: string }
        Returns: {
          created_at: string
          created_by: string
          email: string
          is_active: boolean
          user_id: string
        }[]
      }
      admin_access_health: { Args: never; Returns: Json }
      admin_access_users: {
        Args: {
          p_billing_source?: string
          p_has_access?: boolean
          p_limit?: number
          p_offset?: number
          p_plan_code?: string
          p_role?: string
          p_search?: string
          p_status_filter?: string
          p_vineyard_id?: string
        }
        Returns: {
          access_source: string
          account_created_at: string
          billing_provider: string
          can_use_android_app: boolean
          can_use_ios_app: boolean
          cancel_at_period_end: boolean
          current_period_end: string
          email: string
          email_confirmed: boolean
          full_name: string
          has_access: boolean
          is_disabled: boolean
          is_system_admin: boolean
          last_sign_in_at: string
          last_verified_at: string
          licence_count: number
          manual_override: boolean
          plan_code: string
          plan_name: string
          portal_access: boolean
          product_id: string
          purchase_platform: string
          reason_code: string
          review_status: string
          subscription_status: string
          total_count: number
          unlimited_licences: boolean
          user_id: string
          vineyards: Json
        }[]
      }
      admin_acknowledge_billing_alert: {
        Args: { p_alert_id: string }
        Returns: boolean
      }
      admin_assign_licence: {
        Args: {
          p_reason: string
          p_subscription_id: string
          p_user_id: string
          p_vineyard_id?: string
        }
        Returns: string
      }
      admin_available_licence_pools: {
        Args: {
          p_billing_owner_user_id?: string
          p_has_available_seats?: boolean
          p_limit?: number
          p_offset?: number
          p_plan_code?: string
          p_search?: string
          p_vineyard_id?: string
        }
        Returns: {
          assigned_licences: number
          available_licences: number
          billing_owner_email: string
          billing_owner_name: string
          billing_owner_user_id: string
          billing_source: string
          current_period_end: string
          expires_at: string
          is_assignable: boolean
          is_unlimited: boolean
          licence_limit: number
          not_assignable_reason: string
          plan_code: string
          provider: string
          starts_at: string
          subscription_id: string
          subscription_status: string
          total_count: number
          vineyard_id: string
          vineyard_name: string
        }[]
      }
      admin_billing_alerts: {
        Args: { p_include_acknowledged?: boolean; p_limit?: number }
        Returns: {
          acknowledged_at: string | null
          acknowledged_by: string | null
          alert_type: string
          created_at: string
          detail: string | null
          event_type: string | null
          id: string
          product_id: string | null
          provider: string | null
          provider_event_id: string | null
          resolved_user_id: string | null
          severity: string
        }[]
        SetofOptions: {
          from: "*"
          to: "billing_admin_alerts"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      admin_billing_review_items: {
        Args: {
          p_item_type: string
          p_limit?: number
          p_offset?: number
          p_status?: string
        }
        Returns: {
          created_at: string
          dismissed_at: string
          dismissed_by: string
          is_retryable: boolean
          item_id: string
          item_type: string
          last_attempt_at: string
          platform: string
          product: string
          provider: string
          reason: string
          resolved_at: string
          resolved_by: string
          retry_count: number
          severity: string
          status: string
          total_count: number
          user_email: string
          user_id: string
        }[]
      }
      admin_close_spray_record_from_trip: {
        Args: { p_reason: string; p_trip_id: string }
        Returns: Json
      }
      admin_create_billing_grant: {
        Args: {
          p_expires_at?: string
          p_grant_scope?: string
          p_grant_type: string
          p_owner_user_id: string
          p_reason: string
          p_starts_at?: string
          p_vineyard_id?: string
        }
        Returns: string
      }
      admin_dismiss_billing_review_item: {
        Args: { p_item_id: string; p_item_type: string; p_reason: string }
        Returns: Json
      }
      admin_engagement_summary: {
        Args: never
        Returns: {
          new_users_last_30_days: number
          pending_invitations: number
          signed_in_last_30_days: number
          signed_in_last_7_days: number
          total_pins: number
          total_spray_records: number
          total_users: number
          total_vineyards: number
          total_work_tasks: number
        }[]
      }
      admin_explain_vineyard_access: {
        Args: { p_user_id: string; p_vineyard_id: string }
        Returns: Json
      }
      admin_extend_billing_grant: {
        Args: {
          p_new_expires_at: string
          p_reason: string
          p_subscription_id: string
        }
        Returns: string
      }
      admin_force_stop_trip: {
        Args: { p_end_time: string; p_reason: string; p_trip_id: string }
        Returns: Json
      }
      admin_get_integration: { Args: { p_client_id: string }; Returns: Json }
      admin_get_integration_diagnostics: {
        Args: { p_client_id: string }
        Returns: Json
      }
      admin_get_trip: { Args: { p_trip_id: string }; Returns: Json }
      admin_grant_unlimited_access: {
        Args: {
          p_expires_at?: string
          p_owner_user_id: string
          p_reason?: string
          p_vineyard_id?: string
        }
        Returns: string
      }
      admin_integration_api_metrics: {
        Args: { p_client_id?: string; p_group_by?: string; p_window?: string }
        Returns: Json
      }
      admin_list_billing_grants: {
        Args: never
        Returns: {
          active_licences: number
          created_at: string
          grant_scope: string
          grant_type: string
          is_active: boolean
          licences_display: string
          manual_grant_expires_at: string
          manual_grant_reason: string
          manual_grant_revoked_at: string
          owner_email: string
          owner_full_name: string
          owner_user_id: string
          plan_code: string
          plan_name: string
          platforms_display: string
          primary_vineyard_id: string
          seats_total: number
          starts_at: string
          status: string
          subscription_id: string
          unlimited_licences: boolean
          updated_at: string
          vineyard_name: string
        }[]
      }
      admin_list_integration_api_requests: {
        Args: {
          p_api_key_id?: string
          p_before_created_at?: string
          p_before_id?: string
          p_client_id?: string
          p_errors_only?: boolean
          p_from?: string
          p_limit?: number
          p_method?: string
          p_path?: string
          p_rate_limited_only?: boolean
          p_status_class?: string
          p_status_code?: number
          p_to?: string
          p_unauthenticated_only?: boolean
          p_vineyard_id?: string
        }
        Returns: Json
      }
      admin_list_integration_audit: {
        Args: {
          p_action?: string
          p_actor_user_id?: string
          p_before_created_at?: string
          p_before_id?: string
          p_client_id?: string
          p_from?: string
          p_limit?: number
          p_to?: string
          p_vineyard_id?: string
        }
        Returns: Json
      }
      admin_list_integrations: {
        Args: {
          p_activity?: string
          p_before_created_at?: string
          p_before_id?: string
          p_created_from?: string
          p_created_to?: string
          p_environment?: string
          p_errors_only?: boolean
          p_health?: string
          p_last_used_from?: string
          p_last_used_to?: string
          p_limit?: number
          p_owner_query?: string
          p_owner_user_id?: string
          p_rate_limited_only?: boolean
          p_status?: string
          p_vineyard_id?: string
        }
        Returns: Json
      }
      admin_list_invitations: {
        Args: never
        Returns: {
          created_at: string
          email: string
          expires_at: string
          id: string
          invited_by: string
          invited_by_email: string
          role: string
          status: string
          vineyard_id: string
          vineyard_name: string
        }[]
      }
      admin_list_manual_unlimited_grants: {
        Args: never
        Returns: {
          active_licences: number
          created_at: string
          is_active: boolean
          manual_grant_expires_at: string
          manual_grant_reason: string
          manual_grant_revoked_at: string
          owner_email: string
          owner_full_name: string
          owner_user_id: string
          primary_vineyard_id: string
          status: string
          subscription_id: string
          unlimited_licences: boolean
          updated_at: string
          vineyard_name: string
        }[]
      }
      admin_list_pins: {
        Args: { p_limit?: number }
        Returns: {
          category: string
          created_at: string
          id: string
          is_completed: boolean
          mode: string
          paddock_id: string
          paddock_name: string
          row_number: number
          side: string
          status: string
          title: string
          updated_at: string
          vineyard_id: string
          vineyard_name: string
        }[]
      }
      admin_list_spray_records: {
        Args: { p_limit?: number }
        Returns: {
          created_at: string
          date: string
          id: string
          operation_type: string
          spray_reference: string
          vineyard_id: string
          vineyard_name: string
        }[]
      }
      admin_list_support_requests: {
        Args: { p_limit?: number }
        Returns: {
          app_build: string
          app_platform: string
          app_version: string
          attachment_count: number
          attachment_paths: string[]
          category: string
          created_at: string
          device_model: string
          email_error: string
          email_provider_id: string
          email_sent_at: string
          email_status: string
          id: string
          message: string
          os_version: string
          status: string
          subject: string
          submitter_email: string
          submitter_name: string
          user_id: string
          vineyard_id: string
          vineyard_name: string
        }[]
      }
      admin_list_trips: {
        Args: {
          p_from?: string
          p_limit?: number
          p_to?: string
          p_vineyard_id?: string
        }
        Returns: Json[]
      }
      admin_list_user_login_activity: {
        Args: {
          p_app_type?: string
          p_app_version?: string
          p_os_name?: string
          p_platform?: string
          p_seen_before?: string
          p_seen_since?: string
        }
        Returns: {
          account_created_at: string
          app_build: string
          app_platform: string
          app_version: string
          client_count: number
          device_model: string
          display_name: string
          email: string
          last_app_build: string
          last_app_type: string
          last_app_version: string
          last_client_seen_at: string
          last_device_family: string
          last_device_model: string
          last_os_name: string
          last_os_version: string
          last_platform: string
          last_sign_in_at: string
          os_version: string
          roles: string[]
          status: string
          user_id: string
          vineyard_ids: string[]
          vineyard_names: string[]
        }[]
      }
      admin_list_user_vineyards: {
        Args: { p_user_id: string }
        Returns: {
          country: string
          created_at: string
          deleted_at: string
          id: string
          is_owner: boolean
          member_count: number
          name: string
          role: string
        }[]
      }
      admin_list_users: {
        Args: never
        Returns: {
          block_count: number
          created_at: string
          email: string
          full_name: string
          id: string
          last_sign_in_at: string
          owned_count: number
          updated_at: string
          vineyard_count: number
        }[]
      }
      admin_list_vineyard_members: {
        Args: { p_vineyard_id: string }
        Returns: {
          display_name: string
          email: string
          full_name: string
          joined_at: string
          membership_id: string
          role: string
          user_id: string
          worker_type_id: string
        }[]
      }
      admin_list_vineyard_paddocks: {
        Args: { p_vineyard_id: string }
        Returns: {
          created_at: string
          deleted_at: string
          id: string
          name: string
          polygon_points: Json
          row_count: number
          row_direction: number
          row_width: number
          rows: Json
          updated_at: string
          vine_spacing: number
          vineyard_id: string
        }[]
      }
      admin_list_vineyards: {
        Args: never
        Returns: {
          country: string
          created_at: string
          deleted_at: string
          id: string
          member_count: number
          name: string
          owner_email: string
          owner_full_name: string
          owner_id: string
          pending_invites: number
        }[]
      }
      admin_list_webhook_deliveries: {
        Args: {
          p_before_created_at?: string
          p_before_id?: string
          p_client_id?: string
          p_endpoint_id?: string
          p_event_type?: string
          p_from?: string
          p_is_test?: boolean
          p_limit?: number
          p_status?: string
          p_to?: string
          p_vineyard_id?: string
        }
        Returns: Json
      }
      admin_list_webhook_endpoints: {
        Args: {
          p_before_created_at?: string
          p_before_id?: string
          p_client_id?: string
          p_failing_only?: boolean
          p_include_deleted?: boolean
          p_limit?: number
          p_status?: string
        }
        Returns: Json
      }
      admin_list_work_tasks: {
        Args: { p_limit?: number }
        Returns: {
          created_at: string
          date: string
          duration_hours: number
          id: string
          paddock_name: string
          task_type: string
          vineyard_id: string
          vineyard_name: string
        }[]
      }
      admin_platform_action_stats: {
        Args: { p_days?: number }
        Returns: {
          action_key: string
          category: string
          created_count: number
          deleted_count: number
          edited_count: number
          label: string
          user_count: number
          vineyard_count: number
        }[]
      }
      admin_platform_scale: {
        Args: never
        Returns: {
          average_hectares_per_vineyard: number
          total_active_paddocks: number
          total_hectares_under_management: number
          total_paddocks_with_area: number
          total_vineyards: number
        }[]
      }
      admin_reactivate_integration: {
        Args: { p_client_id: string }
        Returns: Json
      }
      admin_reconcile_trip_runtime: {
        Args: { p_reason: string; p_trip_id: string }
        Returns: Json
      }
      admin_refresh_user_entitlement: {
        Args: { p_user_id: string }
        Returns: Json
      }
      admin_remove_licence: {
        Args: { p_licence_id: string; p_reason: string }
        Returns: string
      }
      admin_resolve_billing_review_item: {
        Args: { p_item_id: string; p_item_type: string; p_reason: string }
        Returns: Json
      }
      admin_retry_billing_delivery: {
        Args: { p_item_id: string; p_reason?: string }
        Returns: Json
      }
      admin_revoke_account_trial: {
        Args: { p_reason: string; p_user_id: string }
        Returns: Json
      }
      admin_revoke_billing_grant: {
        Args: {
          p_reason: string
          p_revoke_licences?: boolean
          p_subscription_id: string
        }
        Returns: string
      }
      admin_revoke_integration_api_key: {
        Args: { p_api_key_id: string; p_reason?: string }
        Returns: Json
      }
      admin_revoke_unlimited_access: {
        Args: { p_revoke_licences?: boolean; p_subscription_id: string }
        Returns: string
      }
      admin_set_member_role: {
        Args: { p_membership_id: string; p_new_role: string }
        Returns: {
          display_name: string | null
          id: string
          joined_at: string
          role: string
          user_id: string
          vineyard_id: string
          worker_type_id: string | null
        }
        SetofOptions: {
          from: "*"
          to: "vineyard_members"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      admin_set_webhook_endpoint_status: {
        Args: { p_endpoint_id: string; p_reason?: string; p_status: string }
        Returns: Json
      }
      admin_store_billing_monitor: { Args: never; Returns: Json }
      admin_store_subscription_diagnostics: {
        Args: { p_limit?: number }
        Returns: {
          cancel_at_period_end: boolean
          current_period_end: string
          environment: string
          expired_at: string
          external_subscription_ref: string
          failed_events: number
          grace_period_end: string
          last_provider_event: string
          last_provider_event_at: string
          last_verified_at: string
          last_webhook_received_at: string
          needs_review_events: number
          plan_code: string
          product_id: string
          provider: string
          purchase_platform: string
          review_status: string
          status: string
          user_id: string
        }[]
      }
      admin_suspend_integration: {
        Args: { p_client_id: string; p_reason?: string }
        Returns: Json
      }
      admin_update_billing_review_item: {
        Args: {
          p_action: string
          p_item_id: string
          p_item_type: string
          p_reason?: string
          p_target_user_id?: string
        }
        Returns: Json
      }
      admin_user_access_detail: { Args: { p_user_id: string }; Returns: Json }
      admin_user_access_history: {
        Args: { p_limit?: number; p_user_id: string }
        Returns: {
          detail: Json
          event_type: string
          occurred_at: string
          platform: string
          source: string
        }[]
      }
      admin_user_activity_platform_details: {
        Args: never
        Returns: {
          app_build: string
          app_type: string
          app_version: string
          browser_name: string
          browser_version: string
          device_family: string
          device_model: string
          last_seen_at: string
          os_name: string
          os_version: string
          platform: string
          user_id: string
        }[]
      }
      admin_user_activity_platforms: {
        Args: never
        Returns: {
          app_type: string
          browser_name: string
          browser_version: string
          last_seen_at: string
          user_id: string
        }[]
      }
      admin_user_client_activity: {
        Args: { p_user_id: string }
        Returns: {
          app_build: string
          app_type: string
          app_version: string
          browser_name: string
          browser_version: string
          client_reference: string
          device_family: string
          device_model: string
          first_seen_at: string
          is_current: boolean
          last_seen_at: string
          last_vineyard_name: string
          os_name: string
          os_version: string
          platform: string
        }[]
      }
      admin_validate_user_store_entitlement: {
        Args: { p_user_id: string }
        Returns: Json
      }
      admin_vineyard_activity_counts: {
        Args: never
        Returns: {
          pin_count: number
          spray_record_count: number
          trip_count: number
          vineyard_id: string
          work_task_count: number
        }[]
      }
      admin_webhook_metrics: {
        Args: { p_client_id?: string; p_window?: string }
        Returns: Json
      }
      apply_pruning_activity_allocation: {
        Args: {
          p_activity_id: string
          p_allocation: Json
          p_allocation_index: number
          p_client_updated_at: string
          p_entry_date: string
          p_method: string
          p_notes: string
          p_vineyard_id: string
          p_vintage_year: number
          p_worker: string
        }
        Returns: Json
      }
      apply_trip_occurrence_action_v1: {
        Args: {
          p_action: Json
          p_expected_plan_revision: number
          p_expected_revision: number
          p_operation_id: string
          p_trip_id: string
        }
        Returns: Json
      }
      approve_chemical_v3_revision: {
        Args: { p_note?: string; p_revision_id: string }
        Returns: string
      }
      archive_manual_rainfall: {
        Args: { p_date: string; p_vineyard_id: string }
        Returns: undefined
      }
      archive_spray_job: { Args: { p_id: string }; Returns: undefined }
      archive_vineyard: { Args: { p_vineyard_id: string }; Returns: Json }
      archive_vineyard_grape_clone: {
        Args: { p_id: string }
        Returns: {
          clone_key: string
          created_at: string
          display_name: string
          id: string
          is_active: boolean
          is_custom: boolean
          updated_at: string
          variety_key: string
          vineyard_id: string
        }
        SetofOptions: {
          from: "*"
          to: "vineyard_grape_clones"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      archive_vineyard_grape_variety: {
        Args: { p_id: string }
        Returns: {
          created_at: string
          display_name: string
          id: string
          is_active: boolean
          is_custom: boolean
          optimal_gdd_override: number | null
          updated_at: string
          variety_key: string
          vineyard_id: string
        }
        SetofOptions: {
          from: "*"
          to: "vineyard_grape_varieties"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      archive_vineyard_rootstock: {
        Args: { p_id: string }
        Returns: {
          created_at: string
          display_name: string
          id: string
          is_active: boolean
          is_custom: boolean
          rootstock_key: string
          updated_at: string
          vineyard_id: string
        }
        SetofOptions: {
          from: "*"
          to: "vineyard_rootstocks"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      archive_vineyard_trip_function: {
        Args: { p_id: string }
        Returns: undefined
      }
      backfill_pruning_season_assignment: {
        Args: { p_dry_run?: boolean; p_vineyard_id?: string }
        Returns: Json
      }
      calculate_irrigation_preview: {
        Args: {
          p_calculation_method: string
          p_duration_minutes: number
          p_flow_litres_per_hour?: number
          p_meter_finish_litres?: number
          p_meter_start_litres?: number
          p_session_date: string
          p_total_volume_litres?: number
          p_valve_id: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      can_add_vintage_notes: {
        Args: { p_vineyard_id: string }
        Returns: boolean
      }
      can_manage_vineyard_damage: {
        Args: { p_vineyard_id: string }
        Returns: boolean
      }
      can_use_vineyard_insights: {
        Args: { p_vineyard_id: string }
        Returns: boolean
      }
      can_view_vineyard_insights: {
        Args: { p_vineyard_id: string }
        Returns: boolean
      }
      cancel_invitation: {
        Args: { p_invitation_id: string }
        Returns: {
          created_at: string
          email: string
          expires_at: string | null
          id: string
          invited_by: string | null
          role: string
          status: string
          updated_at: string
          vineyard_id: string
          worker_type_id: string | null
        }[]
        SetofOptions: {
          from: "*"
          to: "invitations"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      cancel_trip_activity_v1: {
        Args: {
          p_application: string
          p_client_baseline?: Json
          p_compliance_facts?: Json
          p_operation_id: string
          p_trip_id: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      capture_trip_labour_start_v1: {
        Args: {
          p_captured_at: string
          p_hourly_rate: number
          p_trip_id: string
          p_worker_type_id: string
          p_worker_type_name: string
          p_worker_user_id: string
        }
        Returns: undefined
      }
      capture_trip_weather_observation_v1: {
        Args: {
          p_humidity_pct?: number
          p_is_stale?: boolean
          p_observed_at: string
          p_rain_mm?: number
          p_sample_slot: string
          p_source: string
          p_source_kind: string
          p_station_id?: string
          p_temperature_c?: number
          p_trip_id: string
          p_wind_direction_deg?: number
          p_wind_gust_kmh?: number
          p_wind_speed_kmh?: number
        }
        Returns: {
          captured_at: string
          humidity_pct: number | null
          id: string
          is_stale: boolean
          observed_at: string | null
          provider: string | null
          provider_record_id: string | null
          rain_mm: number | null
          retrieval_mode: string
          retrieved_at: string
          sample_slot: string
          source: string
          source_kind: string
          station_id: string | null
          station_name: string | null
          temperature_c: number | null
          trip_id: string
          vineyard_id: string
          wind_direction_deg: number | null
          wind_gust_kmh: number | null
          wind_speed_kmh: number | null
        }
        SetofOptions: {
          from: "*"
          to: "trip_weather_observations"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      chemical_inventory_base_unit: {
        Args: { p_unit: string }
        Returns: string
      }
      chemical_inventory_canonical_unit: {
        Args: { p_unit: string }
        Returns: string
      }
      chemical_inventory_mark_finished: {
        Args: { p_notes?: string; p_saved_chemical_id: string }
        Returns: string
      }
      chemical_inventory_purchase_history: {
        Args: { p_saved_chemical_id: string }
        Returns: {
          batch_number: string
          created_at: string
          currency: string
          display_cost_unit: string
          expiry_date: string
          invoice_reference: string
          notes: string
          purchase_date: string
          purchase_id: string
          quantity: number
          supplier: string
          total_cost: number
          unit: string
          unit_cost: number
        }[]
      }
      chemical_inventory_purchase_history_v2: {
        Args: { p_saved_chemical_id: string }
        Returns: {
          batch_date: string
          batch_number: string
          container_count: number
          container_size: number
          container_unit: string
          created_at: string
          currency: string
          display_cost_unit: string
          expiry_date: string
          invoice_reference: string
          notes: string
          purchase_date: string
          purchase_id: string
          quantity: number
          serial_number: string
          supplier: string
          total_cost: number
          unit: string
          unit_cost: number
        }[]
      }
      chemical_inventory_reader_role: {
        Args: { p_saved_chemical_id: string }
        Returns: string
      }
      chemical_inventory_record_purchase: {
        Args: {
          p_batch_number?: string
          p_currency?: string
          p_expiry_date?: string
          p_invoice_reference?: string
          p_notes?: string
          p_purchase_date: string
          p_quantity: number
          p_saved_chemical_id: string
          p_supplier?: string
          p_total_cost: number
          p_unit: string
        }
        Returns: string
      }
      chemical_inventory_record_purchase_v2: {
        Args: {
          p_batch_date?: string
          p_batch_number?: string
          p_container_count: number
          p_container_size: number
          p_container_unit: string
          p_currency?: string
          p_expiry_date?: string
          p_invoice_reference?: string
          p_notes?: string
          p_purchase_date: string
          p_saved_chemical_id: string
          p_serial_number?: string
          p_supplier?: string
          p_total_cost: number
        }
        Returns: string
      }
      chemical_inventory_record_stocktake: {
        Args: {
          p_effective_at?: string
          p_notes?: string
          p_quantity: number
          p_reason?: string
          p_saved_chemical_id: string
          p_unit: string
        }
        Returns: string
      }
      chemical_inventory_record_stocktake_v2: {
        Args: {
          p_container_count?: number
          p_container_size?: number
          p_container_unit?: string
          p_current_quantity: number
          p_current_unit: string
          p_effective_at?: string
          p_notes?: string
          p_reason?: string
          p_saved_chemical_id: string
        }
        Returns: string
      }
      chemical_inventory_require_manager: {
        Args: { p_saved_chemical_id: string }
        Returns: undefined
      }
      chemical_inventory_require_purchase_writer: {
        Args: { p_saved_chemical_id: string }
        Returns: undefined
      }
      chemical_inventory_set_settings: {
        Args: {
          p_low_stock_percent?: number
          p_low_stock_threshold_quantity?: number
          p_low_stock_threshold_unit?: string
          p_saved_chemical_id: string
          p_warnings_enabled?: boolean
        }
        Returns: undefined
      }
      chemical_inventory_summary: {
        Args: { p_saved_chemical_id: string }
        Returns: {
          currency: string
          current_quantity: number
          current_quantity_base: number
          display_unit: string
          estimated_stock_value: number
          gross_available_quantity: number
          last_stocktake_at: string
          latest_batch_date: string
          latest_batch_number: string
          latest_purchase_date: string
          latest_serial_number: string
          latest_unit_cost: number
          low_stock: boolean
          low_stock_threshold_quantity: number
          out_of_stock: boolean
          percent_remaining: number
          saved_chemical_id: string
          tracked: boolean
          tracking_status: string
          used_since_stocktake: number
          vineyard_id: string
          warnings_enabled: boolean
        }[]
      }
      chemical_inventory_to_base: {
        Args: { p_quantity: number; p_unit: string }
        Returns: number
      }
      chemical_inventory_usage_base: {
        Args: { p_saved_chemical_id: string; p_since: string }
        Returns: number
      }
      chemical_season_purchase_prices: {
        Args: { p_as_of?: string; p_vineyard_id: string; p_vintage: number }
        Returns: {
          base_unit: string
          currency: string
          pricing_basis: string
          purchase_count: number
          saved_chemical_id: string
          total_purchase_cost: number
          total_quantity_base: number
          vintage: number
          warning: string
          weighted_cost_per_base_unit: number
        }[]
      }
      chemical_v3_add_to_vineyard: {
        Args: {
          p_opening_quantity?: number
          p_opening_unit?: string
          p_revision_id: string
          p_vineyard_id: string
        }
        Returns: {
          reused: boolean
          saved_chemical_id: string
          v3_status: string
        }[]
      }
      chemical_v3_admin_approved_catalogue: {
        Args: never
        Returns: {
          activity_group_scheme: string
          activity_groups: string[]
          approved_at: string
          country_code: string
          front_label_image_path: string
          last_verified_at: string
          manufacturer: string
          manufacturer_label_url: string
          product_category_key: string
          product_category_label: string
          product_id: string
          product_name: string
          resistance_classification_state: string
          resistance_group_source: string
          revision_id: string
          unresolved_count: number
          warning_count: number
        }[]
      }
      chemical_v3_admin_delete_rate_option: {
        Args: { p_option_id: string; p_revision_id: string }
        Returns: undefined
      }
      chemical_v3_admin_register_front_label_upload: {
        Args: { p_revision_id: string; p_storage_path: string }
        Returns: string
      }
      chemical_v3_admin_review_issues: {
        Args: { p_revision_id: string }
        Returns: {
          action_type: string
          decided_at: string
          detail: string
          issue_id: string
          issue_key: string
          options: Json
          resolution_code: string
          resolution_note: string
          resolution_payload: Json
          severity: string
          status: string
          title: string
        }[]
      }
      chemical_v3_admin_review_queue: {
        Args: never
        Returns: {
          catalogue_match_manufacturer: string
          catalogue_match_name: string
          catalogue_match_product_id: string
          catalogue_match_reason: string
          catalogue_match_revision_id: string
          catalogue_match_score: number
          core_fields_complete: boolean
          country_code: string
          created_at: string
          front_label_image_path: string
          job_id: string
          manufacturer: string
          manufacturer_label_url: string
          product_category: string
          product_id: string
          product_name: string
          revision_id: string
          unresolved_fields: string[]
          vineyard_rate_status: string
          warnings: Json
        }[]
      }
      chemical_v3_admin_review_queue_requesters: {
        Args: never
        Returns: {
          requested_by: string
          requested_by_email: string
          requested_by_name: string
          revision_id: string
          vineyard_id: string
          vineyard_name: string
        }[]
      }
      chemical_v3_admin_save_rate_option: {
        Args: {
          p_application_method?: string
          p_basis?: string
          p_condition?: string
          p_max_value?: number
          p_min_value?: number
          p_needs_review?: boolean
          p_option_id?: string
          p_raw_text?: string
          p_revision_id: string
          p_targets?: string[]
          p_unit?: string
          p_value?: number
        }
        Returns: string
      }
      chemical_v3_admin_set_active_ingredients: {
        Args: { p_active_ingredients: Json; p_revision_id: string }
        Returns: Json
      }
      chemical_v3_available_front_labels: {
        Args: { p_revision_id: string }
        Returns: {
          created_at: string
          original_url: string
          physical_page: number
          selected: boolean
          source_revision_id: string
          storage_path: string
        }[]
      }
      chemical_v3_match_revision_to_catalogue: {
        Args: {
          p_catalogue_product_id: string
          p_note?: string
          p_revision_id: string
        }
        Returns: {
          catalogue_product_id: string
          catalogue_revision_id: string
          saved_chemicals_relinked: number
        }[]
      }
      chemical_v3_normalise_category: {
        Args: { p_value: string }
        Returns: string
      }
      chemical_v3_physical_form: { Args: { p_form: string }; Returns: string }
      chemical_v3_promote_saved_chemicals: {
        Args: {
          p_product_id: string
          p_revision_id: string
          p_verified_at: string
        }
        Returns: number
      }
      chemical_v3_recompute_core_fields_complete: {
        Args: { p_revision_id: string }
        Returns: undefined
      }
      chemical_v3_replace_ingested_rate_options: {
        Args: { p_options: Json; p_revision_id: string }
        Returns: number
      }
      chemical_v3_resolve_review_issue: {
        Args: {
          p_decision: string
          p_issue_id: string
          p_note?: string
          p_payload?: Json
        }
        Returns: undefined
      }
      chemical_v3_seed_review_issues: {
        Args: { p_revision_id: string }
        Returns: number
      }
      chemical_v3_set_front_label_image: {
        Args: { p_revision_id: string; p_storage_path: string }
        Returns: undefined
      }
      chemical_v3_set_manufacturer_label_url: {
        Args: { p_note?: string; p_revision_id: string; p_url: string }
        Returns: undefined
      }
      chemical_v3_set_manufacturer_product_url: {
        Args: { p_note?: string; p_revision_id: string; p_url: string }
        Returns: undefined
      }
      chemical_v3_set_product_category: {
        Args: { p_category_key: string; p_revision_id: string }
        Returns: undefined
      }
      chemical_v3_set_research_hints: {
        Args: {
          p_job_id: string
          p_manufacturer_label_url?: string
          p_manufacturer_product_url?: string
          p_product_name?: string
          p_research_notes?: string
        }
        Returns: Json
      }
      chemical_v3_set_resistance_groups: {
        Args: {
          p_groups: string[]
          p_revision_id: string
          p_scheme: string
          p_source?: string
          p_state?: string
        }
        Returns: undefined
      }
      chemical_v3_sync_rate_options_json: {
        Args: { p_revision_id: string }
        Returns: undefined
      }
      claim_pin_location_enrichment: {
        Args: { p_lease_seconds?: number; p_limit?: number }
        Returns: {
          attempts: number
          available_at: string
          evidence_revision: number
          last_error: string | null
          lease_expires_at: string | null
          lease_token: string | null
          pin_id: string
          resolver_version: string
          terminal_at: string | null
        }[]
        SetofOptions: {
          from: "*"
          to: "pin_location_enrichment_queue"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      claim_scout_photo_cleanup: {
        Args: { p_limit?: number; p_vineyard_id: string }
        Returns: {
          attempt_count: number
          completed_at: string | null
          created_at: string
          id: string
          last_error: string | null
          lease_expires_at: string | null
          lease_token: string | null
          leased_at: string | null
          next_attempt_at: string
          photo_id: string
          scout_visit_id: string
          status: string
          storage_path: string
          vineyard_id: string
        }[]
        SetofOptions: {
          from: "*"
          to: "scout_photo_cleanup_queue"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      commit_irrigation_import: {
        Args: {
          p_acknowledge_current_configuration?: boolean
          p_batch_id: string
          p_row_ids?: string[]
        }
        Returns: Json
      }
      commit_mait_intelliweb_usage_event: {
        Args: { p_actor_user_id: string; p_event_id: string }
        Returns: Json
      }
      commit_pin_location_enrichment: {
        Args: {
          p_evidence_revision: number
          p_lease_token: string
          p_pin_id: string
          p_resolver_version: string
        }
        Returns: string
      }
      complete_scout_photo_cleanup: {
        Args: { p_id: string; p_lease_token: string }
        Returns: boolean
      }
      complete_spray_record: {
        Args: { p_allow_unlinked?: boolean; p_spray_record_id: string }
        Returns: Json
      }
      confirm_saved_pin_location: {
        Args: {
          p_along_row_distance_m: number
          p_driving_row: number
          p_evidence_revision: number
          p_paddock_id: string
          p_pin_id: string
          p_pin_row: number
          p_pin_side: string
          p_snapped_latitude: number
          p_snapped_longitude: number
        }
        Returns: {
          along_row_distance_m: number | null
          assigned_user_id: string | null
          button_color: string | null
          button_name: string | null
          category: string | null
          client_updated_at: string | null
          completed_at: string | null
          completed_by: string | null
          completed_by_user_id: string | null
          created_at: string
          created_by: string | null
          custom_type_id: string | null
          deleted_at: string | null
          driving_row_number: number | null
          due_date: string | null
          growth_stage_code: string | null
          heading: number | null
          id: string
          is_completed: boolean
          latitude: number | null
          launcher_button_id: string | null
          linked_work_task_id: string | null
          location_confirmation_revision: number | null
          location_confirmed_at: string | null
          location_confirmed_by: string | null
          location_enriched_at: string | null
          location_enrichment_revision: number | null
          location_enrichment_status: string | null
          location_resolver_version: string | null
          location_scope: string | null
          longitude: number | null
          mode: string | null
          notes: string | null
          paddock_id: string | null
          photo_path: string | null
          pin_row_number: number | null
          pin_side: string | null
          priority: string | null
          row_number: number | null
          side: string | null
          snapped_latitude: number | null
          snapped_longitude: number | null
          snapped_to_row: boolean
          status: string | null
          sync_version: number
          title: string | null
          trip_id: string | null
          updated_at: string
          updated_by: string | null
          vineyard_id: string
        }
        SetofOptions: {
          from: "*"
          to: "pins"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      confirm_saved_pin_location_v2: {
        Args: {
          p_along_row_distance_m: number
          p_driving_row: number
          p_evidence_revision: number
          p_expected_sync_version: number
          p_operation_id: string
          p_paddock_id: string
          p_pin_id: string
          p_pin_row: number
          p_pin_side: string
          p_snapped_latitude: number
          p_snapped_longitude: number
        }
        Returns: string
      }
      confirm_trip_absence_v1: { Args: { p_trip_id: string }; Returns: Json }
      correct_spray_tank_actual_v1: {
        Args: {
          p_actual_id: string
          p_chemicals: Json
          p_expected_version: number
          p_operation_id: string
          p_spray_record_id: string
          p_tank_number: number
          p_tank_session_id: string
          p_trip_id: string
          p_water_volume_l: number
        }
        Returns: Json
      }
      correct_spray_trip_metadata_v1: {
        Args: {
          p_end_engine_hours: number
          p_expected_version: number
          p_fuel_consumption_l_per_hour: number
          p_machine_id: string
          p_operation_id: string
          p_operator_user_id: string
          p_spray_equipment_id: string
          p_start_engine_hours: number
          p_tractor_id: string
          p_trip_id: string
        }
        Returns: Json
      }
      create_custom_pin: {
        Args: {
          p_along_row_distance_m?: number
          p_client_updated_at?: string
          p_custom_type_id?: string
          p_driving_row_number?: number
          p_id: string
          p_latitude?: number
          p_location_scope: string
          p_longitude?: number
          p_notes?: string
          p_paddock_id?: string
          p_pin_row_number?: number
          p_segments?: Json
          p_snapped_latitude?: number
          p_snapped_longitude?: number
          p_snapped_to_row?: boolean
          p_title: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      create_invitation:
        | {
            Args: {
              p_email: string
              p_expires_in_days?: number
              p_operator_category_id?: string
              p_role?: string
              p_vineyard_id: string
            }
            Returns: {
              expires_at: string
              invitation_id: string
              token: string
            }[]
          }
        | {
            Args: {
              p_email: string
              p_expires_at?: string
              p_operator_category_id?: string
              p_role: string
              p_vineyard_id: string
            }
            Returns: {
              created_at: string
              email: string
              expires_at: string | null
              id: string
              invited_by: string | null
              role: string
              status: string
              updated_at: string
              vineyard_id: string
              worker_type_id: string | null
            }[]
            SetofOptions: {
              from: "*"
              to: "invitations"
              isOneToOne: false
              isSetofReturn: true
            }
          }
      create_irrigation_import_batch: {
        Args: {
          p_allow_revalidation?: boolean
          p_file_hash: string
          p_file_name: string
          p_file_size?: number
          p_id: string
          p_provider: string
          p_source_unit_name?: string
          p_timezone?: string
          p_total_rows?: number
          p_vineyard_id: string
          p_worksheet_name?: string
        }
        Returns: Json
      }
      create_irrigation_system: {
        Args: {
          p_controller_name?: string
          p_controller_provider?: string
          p_external_controller_id?: string
          p_id: string
          p_name: string
          p_notes?: string
          p_vineyard_id: string
          p_water_source?: string
        }
        Returns: Json
      }
      create_irrigation_valve: {
        Args: {
          p_configured_flow_litres_per_hour?: number
          p_id: string
          p_irrigation_system_id: string
          p_measured_flow_litres_per_hour?: number
          p_name: string
          p_notes?: string
          p_valve_number?: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      create_manual_issue: {
        Args: {
          p_along_row_distance_m?: number
          p_assigned_user_id?: string
          p_category?: string
          p_client_updated_at?: string
          p_description?: string
          p_driving_row_number?: number
          p_due_date?: string
          p_id: string
          p_latitude?: number
          p_location_scope: string
          p_longitude?: number
          p_paddock_id?: string
          p_pin_row_number?: number
          p_pin_side?: string
          p_priority?: string
          p_segments?: Json
          p_snapped_latitude?: number
          p_snapped_longitude?: number
          p_snapped_to_row?: boolean
          p_title: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      create_trip_with_occurrences_v1: {
        Args: { p_coverage: Json; p_operation_id: string; p_trip: Json }
        Returns: Json
      }
      create_vineyard_custom_pin_type: {
        Args: {
          p_color?: string
          p_icon?: string
          p_id: string
          p_name: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      create_vineyard_spray_target: {
        Args: {
          p_id: string
          p_identifier: string
          p_label: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      create_vineyard_with_owner: {
        Args: { p_country?: string; p_name: string }
        Returns: {
          area_unit: string | null
          country: string | null
          country_code: string | null
          created_at: string
          currency_code: string | null
          current_observation_provider: string | null
          date_format: string | null
          deleted_at: string | null
          distance_unit: string | null
          elevation_metres: number | null
          forecast_provider: string
          fuel_unit: string | null
          id: string
          irrigation_recent_rain_lookback_hours: number
          latitude: number | null
          logo_path: string | null
          logo_updated_at: string | null
          longitude: number | null
          name: string
          owner_id: string | null
          season_start_day: number
          season_start_month: number
          spray_carrier_volume_basis: string | null
          spray_compliance_profile: string | null
          spray_rate_area_unit: string | null
          sugar_measurement_unit: string | null
          terminology_region: string | null
          timezone: string | null
          updated_at: string
          volume_unit: string | null
          yield_samples_per_hectare: number
        }[]
        SetofOptions: {
          from: "*"
          to: "vineyards"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      custom_pin_type_json: {
        Args: {
          t: Database["public"]["Tables"]["vineyard_custom_pin_types"]["Row"]
        }
        Returns: Json
      }
      days_with_better_rainfall_source: {
        Args: { p_from_date: string; p_to_date: string; p_vineyard_id: string }
        Returns: {
          date: string
        }[]
      }
      decline_invitation: {
        Args: { p_invitation_id: string }
        Returns: undefined
      }
      delete_damage_record: {
        Args: { p_damage_record_id: string; p_vineyard_id: string }
        Returns: Json
      }
      delete_fertiliser_record_allocation: {
        Args: { p_id: string }
        Returns: undefined
      }
      delete_linked_pin_growth_v1: {
        Args: { p_growth_stage_record_id?: string; p_pin_id?: string }
        Returns: undefined
      }
      delete_manual_spray_v1: {
        Args: {
          p_manual_entry_id: string
          p_operation_id: string
          p_spray_record_id: string
          p_trip_id: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      delete_or_cancel_manual_issue: {
        Args: { p_action?: string; p_id: string }
        Returns: Json
      }
      delete_paddock_soil_profile: {
        Args: { p_paddock_id: string }
        Returns: undefined
      }
      delete_pruning_entry: { Args: { p_id: string }; Returns: undefined }
      delete_vineyard_default_soil_profile: {
        Args: { p_vineyard_id: string }
        Returns: undefined
      }
      delete_vineyard_weather_integration: {
        Args: { p_provider?: string; p_vineyard_id: string }
        Returns: undefined
      }
      derive_paddock_row_id: {
        Args: {
          p_elat: number
          p_elon: number
          p_number: number
          p_slat: number
          p_slon: number
        }
        Returns: string
      }
      derive_pruning_allocation_id: {
        Args: { p_activity_id: string; p_paddock_id: string }
        Returns: string
      }
      derive_pruning_season_id: {
        Args: {
          p_paddock_id: string
          p_season_year: number
          p_vineyard_id: string
        }
        Returns: string
      }
      discard_contour_row_mapping_draft: {
        Args: {
          p_draft_id: string
          p_expected_revision: number
          p_paddock_id: string
        }
        Returns: Json
      }
      duplicate_spray_job: {
        Args: { p_as_template?: boolean; p_id: string }
        Returns: string
      }
      fail_pin_location_enrichment: {
        Args: {
          p_error: string
          p_evidence_revision: number
          p_lease_token: string
          p_pin_id: string
          p_resolver_version: string
        }
        Returns: string
      }
      fail_scout_photo_cleanup: {
        Args: { p_error: string; p_id: string; p_lease_token: string }
        Returns: boolean
      }
      finalise_trip_labour_v1: {
        Args: { p_trip_id: string }
        Returns: undefined
      }
      finalize_trip_occurrences_v1: {
        Args: {
          p_end: Json
          p_expected_plan_revision: number
          p_expected_revision: number
          p_operation_id: string
          p_reviewed_states: Json
          p_trip_id: string
        }
        Returns: Json
      }
      get_app_release_policy: { Args: { p_platform: string }; Returns: Json }
      get_axisstream_exchange_configuration: {
        Args: { p_vineyard_id: string }
        Returns: Json
      }
      get_canopy_reference_images_v1: { Args: never; Returns: Json }
      get_contour_row_mapping_draft: {
        Args: { p_paddock_id: string }
        Returns: Json
      }
      get_daily_rainfall: {
        Args: { p_from_date: string; p_to_date: string; p_vineyard_id: string }
        Returns: {
          date: string
          notes: string
          rainfall_mm: number
          source: string
          station_id: string
          station_name: string
          updated_at: string
        }[]
      }
      get_fertigation_capabilities: {
        Args: { p_vineyard_id: string }
        Returns: Json
      }
      get_grape_allocation_financials: {
        Args: { p_vineyard_id: string }
        Returns: {
          allocation_id: string
          contract_value: number
          price_per_tonne: number
        }[]
      }
      get_grape_clone_catalog: {
        Args: never
        Returns: {
          aliases: Json
          clone_code: string
          display_name: string
          is_active: boolean
          is_builtin: boolean
          key: string
          selection_system: string
          source_country: string
          source_reference: string
          updated_at: string
          variety_key: string
        }[]
      }
      get_grape_variety_catalog: {
        Args: never
        Returns: {
          aliases: Json
          canonical_name: string
          display_name: string
          is_active: boolean
          is_builtin: boolean
          key: string
          optimal_gdd: number
          updated_at: string
        }[]
      }
      get_irrigation_block_report: {
        Args: {
          p_block_id?: string
          p_calculation_method?: string
          p_date_from?: string
          p_date_to?: string
          p_include_estimated?: boolean
          p_include_imported?: boolean
          p_include_reversed?: boolean
          p_measurement_group?: string
          p_source_group?: string
          p_source_type?: string
          p_system_id?: string
          p_valve_id?: string
          p_variety_id?: string
          p_vineyard_id: string
          p_vintage_year?: number
          p_water_source?: string
        }
        Returns: Json
      }
      get_irrigation_block_summary: {
        Args: {
          p_include_reversed?: boolean
          p_vineyard_id: string
          p_vintage_year?: number
        }
        Returns: Json
      }
      get_irrigation_calculation_source_summary: {
        Args: {
          p_block_id?: string
          p_calculation_method?: string
          p_date_from?: string
          p_date_to?: string
          p_include_estimated?: boolean
          p_include_imported?: boolean
          p_include_reversed?: boolean
          p_measurement_group?: string
          p_source_group?: string
          p_source_type?: string
          p_system_id?: string
          p_valve_id?: string
          p_variety_id?: string
          p_vineyard_id: string
          p_vintage_year?: number
          p_water_source?: string
        }
        Returns: Json
      }
      get_irrigation_capabilities: {
        Args: { p_vineyard_id: string }
        Returns: Json
      }
      get_irrigation_daily_report: {
        Args: {
          p_block_id?: string
          p_calculation_method?: string
          p_date_from?: string
          p_date_to?: string
          p_include_estimated?: boolean
          p_include_imported?: boolean
          p_include_reversed?: boolean
          p_include_zero_days?: boolean
          p_measurement_group?: string
          p_source_group?: string
          p_source_type?: string
          p_system_id?: string
          p_valve_id?: string
          p_variety_id?: string
          p_vineyard_id: string
          p_vintage_year?: number
          p_water_source?: string
        }
        Returns: Json
      }
      get_irrigation_daily_summary: {
        Args: {
          p_include_reversed?: boolean
          p_vineyard_id: string
          p_vintage_year?: number
        }
        Returns: Json
      }
      get_irrigation_fertigation: {
        Args: { p_irrigation_session_id: string }
        Returns: Json
      }
      get_irrigation_import_batch: {
        Args: { p_batch_id: string }
        Returns: Json
      }
      get_irrigation_import_provider_settings: {
        Args: {
          p_external_controller_key?: string
          p_provider: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      get_irrigation_monthly_report: {
        Args: {
          p_block_id?: string
          p_calculation_method?: string
          p_date_from?: string
          p_date_to?: string
          p_include_estimated?: boolean
          p_include_imported?: boolean
          p_include_reversed?: boolean
          p_measurement_group?: string
          p_source_group?: string
          p_source_type?: string
          p_system_id?: string
          p_valve_id?: string
          p_variety_id?: string
          p_vineyard_id: string
          p_vintage_year?: number
          p_water_source?: string
        }
        Returns: Json
      }
      get_irrigation_monthly_summary: {
        Args: {
          p_include_reversed?: boolean
          p_vineyard_id: string
          p_vintage_year?: number
        }
        Returns: Json
      }
      get_irrigation_rainfall_summary: {
        Args: {
          p_block_id?: string
          p_calculation_method?: string
          p_date_from?: string
          p_date_to?: string
          p_group_by?: string
          p_include_estimated?: boolean
          p_include_imported?: boolean
          p_include_reversed?: boolean
          p_measurement_group?: string
          p_source_group?: string
          p_source_type?: string
          p_system_id?: string
          p_valve_id?: string
          p_variety_id?: string
          p_vineyard_id: string
          p_vintage_year?: number
          p_water_source?: string
        }
        Returns: Json
      }
      get_irrigation_record_source_summary: {
        Args: {
          p_block_id?: string
          p_calculation_method?: string
          p_date_from?: string
          p_date_to?: string
          p_include_estimated?: boolean
          p_include_imported?: boolean
          p_include_reversed?: boolean
          p_measurement_group?: string
          p_source_group?: string
          p_source_type?: string
          p_system_id?: string
          p_valve_id?: string
          p_variety_id?: string
          p_vineyard_id: string
          p_vintage_year?: number
          p_water_source?: string
        }
        Returns: Json
      }
      get_irrigation_session: { Args: { p_id: string }; Returns: Json }
      get_irrigation_session_fertigation: {
        Args: { p_irrigation_session_id: string; p_vineyard_id: string }
        Returns: Json
      }
      get_irrigation_setup_status: {
        Args: { p_vineyard_id: string }
        Returns: Json
      }
      get_irrigation_valve_report: {
        Args: {
          p_block_id?: string
          p_calculation_method?: string
          p_date_from?: string
          p_date_to?: string
          p_include_estimated?: boolean
          p_include_imported?: boolean
          p_include_reversed?: boolean
          p_measurement_group?: string
          p_source_group?: string
          p_source_type?: string
          p_system_id?: string
          p_valve_id?: string
          p_variety_id?: string
          p_vineyard_id: string
          p_vintage_year?: number
          p_water_source?: string
        }
        Returns: Json
      }
      get_irrigation_valve_summary: {
        Args: {
          p_include_reversed?: boolean
          p_vineyard_id: string
          p_vintage_year?: number
        }
        Returns: Json
      }
      get_irrigation_variety_report: {
        Args: {
          p_block_id?: string
          p_calculation_method?: string
          p_date_from?: string
          p_date_to?: string
          p_include_estimated?: boolean
          p_include_imported?: boolean
          p_include_reversed?: boolean
          p_measurement_group?: string
          p_source_group?: string
          p_source_type?: string
          p_system_id?: string
          p_valve_id?: string
          p_variety_id?: string
          p_vineyard_id: string
          p_vintage_year?: number
          p_water_source?: string
        }
        Returns: Json
      }
      get_irrigation_variety_summary: {
        Args: {
          p_include_reversed?: boolean
          p_vineyard_id: string
          p_vintage_year?: number
        }
        Returns: Json
      }
      get_irrigation_vintage_overview: {
        Args: {
          p_block_id?: string
          p_calculation_method?: string
          p_date_from?: string
          p_date_to?: string
          p_include_estimated?: boolean
          p_include_imported?: boolean
          p_include_reversed?: boolean
          p_measurement_group?: string
          p_source_group?: string
          p_source_type?: string
          p_system_id?: string
          p_valve_id?: string
          p_variety_id?: string
          p_vineyard_id: string
          p_vintage_year?: number
          p_water_source?: string
        }
        Returns: Json
      }
      get_irrigation_vintage_summary: {
        Args: {
          p_include_reversed?: boolean
          p_vineyard_id: string
          p_vintage_year?: number
        }
        Returns: Json
      }
      get_irrigation_vintage_trends: {
        Args: {
          p_block_id?: string
          p_calculation_method?: string
          p_include_estimated?: boolean
          p_include_imported?: boolean
          p_include_reversed?: boolean
          p_measurement_group?: string
          p_source_group?: string
          p_source_type?: string
          p_system_id?: string
          p_valve_id?: string
          p_variety_id?: string
          p_vineyard_id: string
          p_vintage_count?: number
          p_vintage_year?: number
          p_water_source?: string
        }
        Returns: Json
      }
      get_irrigation_water_source_summary: {
        Args: {
          p_block_id?: string
          p_calculation_method?: string
          p_date_from?: string
          p_date_to?: string
          p_include_estimated?: boolean
          p_include_imported?: boolean
          p_include_reversed?: boolean
          p_measurement_group?: string
          p_source_group?: string
          p_source_type?: string
          p_system_id?: string
          p_valve_id?: string
          p_variety_id?: string
          p_vineyard_id: string
          p_vintage_year?: number
          p_water_source?: string
        }
        Returns: Json
      }
      get_irrigation_weekly_summary: {
        Args: {
          p_block_id?: string
          p_calculation_method?: string
          p_date_from?: string
          p_date_to?: string
          p_include_estimated?: boolean
          p_include_imported?: boolean
          p_include_reversed?: boolean
          p_include_zero_weeks?: boolean
          p_measurement_group?: string
          p_source_group?: string
          p_source_type?: string
          p_system_id?: string
          p_valve_id?: string
          p_variety_id?: string
          p_vineyard_id: string
          p_vintage_year?: number
          p_water_source?: string
        }
        Returns: Json
      }
      get_mait_intelliweb_configuration: {
        Args: { p_vineyard_id: string }
        Returns: Json
      }
      get_mait_intelliweb_controller_mappings: {
        Args: { p_module_id: string; p_vineyard_id: string }
        Returns: Json
      }
      get_manual_issue: { Args: { p_id: string }; Returns: Json }
      get_my_billing_vineyards: {
        Args: never
        Returns: {
          can_manage_billing: boolean
          has_active_subscription: boolean
          has_stripe_customer: boolean
          plan_code: string
          role: string
          subscription_status: string
          vineyard_id: string
          vineyard_name: string
        }[]
      }
      get_my_operational_tool_preferences: { Args: never; Returns: Json }
      get_my_vinetrack_access: {
        Args: never
        Returns: {
          access_source: string
          active_licences: number
          billing_provider: string
          can_use_android_app: boolean
          can_use_ios_app: boolean
          can_use_portal: boolean
          cancel_at_period_end: boolean
          current_period_end: string
          enforcement_enabled: boolean
          expires_at: string
          grace_period_end: string
          has_supabase_access: boolean
          is_owner: boolean
          is_unlimited: boolean
          last_verified_at: string
          licence_id: string
          manual_grant_expires_at: string
          manual_grant_reason: string
          plan_code: string
          plan_name: string
          plan_tier: string
          portal_access: boolean
          portal_access_level: string
          purchase_platform: string
          reason_code: string
          seats_included: number
          seats_purchased: number
          solo_check_required: boolean
          status: string
          subscription_id: string
          trial_end: string
          unlimited_licences: boolean
          user_id: string
          vineyard_id: string
        }[]
      }
      get_my_vineyard_access: { Args: { p_vineyard_id: string }; Returns: Json }
      get_my_vineyard_access_matrix: { Args: never; Returns: Json }
      get_my_vineyard_billing_history: {
        Args: { p_limit?: number; p_offset?: number; p_vineyard_id: string }
        Returns: {
          amount_due: number
          amount_paid: number
          can_download_invoice: boolean
          can_view_invoice: boolean
          created_at: string
          currency: string
          description: string
          invoice_id: string
          invoice_number: string
          invoice_status: string
          paid_at: string
          period_end: string
          period_start: string
          plan_code: string
          product_id: string
          provider: string
          purchase_platform: string
          record_id: string
          record_type: string
          redacted_reference: string
          refunded_at: string
          subscription_status: string
          subtotal: number
          tax: number
          total: number
          total_count: number
          voided_at: string
        }[]
      }
      get_my_vineyard_billing_licences: {
        Args: { p_vineyard_id: string }
        Returns: {
          assigned_at: string
          licence_id: string
          status: string
          user_display_name: string
          user_email: string
          vineyard_id: string
          vineyard_name: string
        }[]
      }
      get_my_vineyard_billing_summary: {
        Args: { p_vineyard_id: string }
        Returns: Json
      }
      get_paddock_soil_profile: {
        Args: { p_paddock_id: string }
        Returns: {
          australian_soil_classification: string | null
          australian_soil_classification_code: string | null
          available_water_capacity_mm_per_m: number | null
          confidence: string | null
          country_code: string | null
          created_at: string
          drainage_risk: string | null
          effective_root_depth_m: number | null
          id: string
          infiltration_risk: string | null
          irrigation_soil_class: string | null
          is_manual_override: boolean
          land_soil_capability: string | null
          land_soil_capability_class: number | null
          lookup_latitude: number | null
          lookup_longitude: number | null
          management_allowed_depletion_percent: number | null
          manual_notes: string | null
          model_version: string
          paddock_id: string | null
          raw_source_json: Json | null
          region_code: string | null
          soil_description: string | null
          soil_landscape: string | null
          soil_landscape_code: string | null
          soil_texture_class: string | null
          source: string
          source_dataset: string | null
          source_feature_id: string | null
          source_name: string | null
          source_provider: string | null
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          waterlogging_risk: string | null
        }[]
        SetofOptions: {
          from: "*"
          to: "paddock_soil_profiles"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      get_picking_record_financials: {
        Args: { p_vineyard_id: string }
        Returns: {
          grape_value: number
          picking_record_id: string
          price_per_tonne: number
          sold_to: string
        }[]
      }
      get_pruning_activity: { Args: { p_activity_id: string }; Returns: Json }
      get_pruning_skipped_summary: {
        Args: { p_season_year?: number; p_vineyard_id: string }
        Returns: Json
      }
      get_pruning_vineyard_summary: {
        Args: {
          p_season_year?: number
          p_today?: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      get_rootstock_catalog: {
        Args: never
        Returns: {
          aliases: Json
          canonical_name: string
          display_name: string
          is_active: boolean
          is_builtin: boolean
          key: string
          parentage: string
          source_reference: string
          updated_at: string
        }[]
      }
      get_season_yield_base_overview: {
        Args: { p_vineyard_id: string; p_vintage: number }
        Returns: Json
      }
      get_soil_class_defaults: {
        Args: never
        Returns: {
          default_allowed_depletion_percent: number
          default_awc_max_mm_per_m: number
          default_awc_min_mm_per_m: number
          default_awc_mm_per_m: number
          default_root_depth_m: number
          description: string
          drainage_risk: string
          infiltration_risk: string
          irrigation_soil_class: string
          label: string
          sort_order: number
          waterlogging_risk: string
        }[]
      }
      get_spray_report_v1: { Args: { p_trip_id: string }; Returns: Json }
      get_spray_report_v1_pre_actual_amendments_v1: {
        Args: { p_trip_id: string }
        Returns: Json
      }
      get_spray_report_v1_pre_canonical_facts_v1: {
        Args: { p_trip_id: string }
        Returns: Json
      }
      get_spray_report_v1_pre_manual_entry_v1: {
        Args: { p_trip_id: string }
        Returns: Json
      }
      get_spray_report_v1_pre_occurrence_v1: {
        Args: { p_trip_id: string }
        Returns: Json
      }
      get_spray_report_v1_pre_weather_provenance_v1: {
        Args: { p_trip_id: string }
        Returns: Json
      }
      get_spray_report_v2: { Args: { p_trip_id: string }; Returns: Json }
      get_system_feature_flags: {
        Args: never
        Returns: {
          category: string
          description: string
          is_enabled: boolean
          key: string
          label: string
          updated_at: string
          value: Json
          value_type: string
        }[]
      }
      get_trip_occurrence_recovery_v1: {
        Args: { p_operation_ids?: string[]; p_trip_id: string }
        Returns: Json
      }
      get_vineyard_current_observation_provider: {
        Args: { p_vineyard_id: string }
        Returns: string
      }
      get_vineyard_current_weather: {
        Args: { p_vineyard_id: string }
        Returns: {
          humidity_pct: number
          is_stale: boolean
          leaf_wetness: number
          message: string
          observed_at: string
          rain_rate_mm_per_hr: number
          rain_today_mm: number
          source: string
          station_id: string
          station_name: string
          status: string
          temperature_c: number
          wind_direction_deg: number
          wind_gust_kmh: number
          wind_speed_kmh: number
        }[]
      }
      get_vineyard_default_soil_profile: {
        Args: { p_vineyard_id: string }
        Returns: {
          australian_soil_classification: string | null
          australian_soil_classification_code: string | null
          available_water_capacity_mm_per_m: number | null
          confidence: string | null
          country_code: string | null
          created_at: string
          drainage_risk: string | null
          effective_root_depth_m: number | null
          id: string
          infiltration_risk: string | null
          irrigation_soil_class: string | null
          is_manual_override: boolean
          land_soil_capability: string | null
          land_soil_capability_class: number | null
          lookup_latitude: number | null
          lookup_longitude: number | null
          management_allowed_depletion_percent: number | null
          manual_notes: string | null
          model_version: string
          paddock_id: string | null
          raw_source_json: Json | null
          region_code: string | null
          soil_description: string | null
          soil_landscape: string | null
          soil_landscape_code: string | null
          soil_texture_class: string | null
          source: string
          source_dataset: string | null
          source_feature_id: string | null
          source_name: string | null
          source_provider: string | null
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          waterlogging_risk: string | null
        }[]
        SetofOptions: {
          from: "*"
          to: "paddock_soil_profiles"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      get_vineyard_forecast_cache: {
        Args: { p_provider: string; p_vineyard_id: string }
        Returns: {
          fetched_at: string
          is_stale: boolean
          payload: Json
          provider: string
          provider_location_ref: string
          provider_updated_at: string
          schema_version: string
          stale_at: string
          timezone: string
        }[]
      }
      get_vineyard_forecast_provider: {
        Args: { p_vineyard_id: string }
        Returns: string
      }
      get_vineyard_location: {
        Args: { p_vineyard_id: string }
        Returns: {
          elevation_metres: number
          latitude: number
          longitude: number
          timezone: string
          vineyard_id: string
        }[]
      }
      get_vineyard_recent_rain_lookback_hours: {
        Args: { p_vineyard_id: string }
        Returns: number
      }
      get_vineyard_recent_rainfall: {
        Args: { p_lookback_hours?: number; p_vineyard_id: string }
        Returns: {
          covered_from: string
          covered_to: string
          davis_days: number
          days_missing: number
          days_with_data: number
          fallback_used: boolean
          lookback_hours: number
          manual_days: number
          open_meteo_days: number
          recent_rain_mm: number
          resolution_path: string
          source: string
          source_label: string
          today_from_cache: boolean
        }[]
      }
      get_vineyard_region_settings: {
        Args: { p_vineyard_id: string }
        Returns: {
          area_unit: string
          country_code: string
          currency_code: string
          date_format: string
          distance_unit: string
          fuel_unit: string
          spray_rate_area_unit: string
          sugar_measurement_unit: string
          terminology_region: string
          timezone: string
          vineyard_id: string
          volume_unit: string
        }[]
      }
      get_vineyard_season_settings: {
        Args: { p_vineyard_id: string }
        Returns: {
          season_start_day: number
          season_start_month: number
          updated_at: string
          vineyard_id: string
        }[]
      }
      get_vineyard_spray_profile: {
        Args: { p_vineyard_id: string }
        Returns: {
          country_code: string
          spray_carrier_volume_basis: string
          spray_compliance_profile: string
          vineyard_id: string
        }[]
      }
      get_vineyard_team_members: {
        Args: { p_vineyard_id: string }
        Returns: {
          avatar_url: string
          display_name: string
          email: string
          full_name: string
          joined_at: string
          membership_id: string
          operator_category_id: string
          operator_category_name: string
          role: string
          user_id: string
          vineyard_id: string
          worker_type_id: string
          worker_type_name: string
        }[]
      }
      get_vineyard_weather_integration: {
        Args: { p_provider?: string; p_vineyard_id: string }
        Returns: {
          caller_role: string
          configured_by: string
          detected_sensors: string[]
          has_api_key: boolean
          has_api_secret: boolean
          has_leaf_wetness: boolean
          has_rain: boolean
          has_temperature_humidity: boolean
          has_wind: boolean
          id: string
          is_active: boolean
          last_test_status: string
          last_tested_at: string
          provider: string
          station_id: string
          station_latitude: number
          station_longitude: number
          station_name: string
          updated_at: string
          vineyard_id: string
        }[]
      }
      get_vineyard_wunderground_config: {
        Args: { p_vineyard_id: string }
        Returns: {
          caller_role: string
          configured_by: string
          has_station: boolean
          is_active: boolean
          last_test_status: string
          last_tested_at: string
          station_id: string
          station_latitude: number
          station_longitude: number
          station_name: string
          updated_at: string
          vineyard_id: string
        }[]
      }
      get_vineyard_yield_sampling_settings: {
        Args: { p_vineyard_id: string }
        Returns: {
          samples_per_hectare: number
          vineyard_id: string
        }[]
      }
      grape_variety_diagnostics: {
        Args: { p_vineyard_id: string }
        Returns: {
          archived_count: number
          builtin_count: number
          custom_count: number
          unresolved_allocations: number
          vineyard_variety_count: number
        }[]
      }
      grape_variety_diagnostics_admin: {
        Args: { p_vineyard_id: string }
        Returns: {
          archived_count: number
          builtin_count: number
          custom_count: number
          unresolved_allocations: number
          vineyard_variety_count: number
        }[]
      }
      hard_delete_draft_spray_job: {
        Args: { p_spray_job_id: string }
        Returns: undefined
      }
      hard_delete_paddock: {
        Args: { p_paddock_id: string }
        Returns: undefined
      }
      hard_delete_scout_visit: {
        Args: {
          p_deleted_at?: string
          p_operation_id: string
          p_vineyard_id: string
          p_visit_id: string
        }
        Returns: boolean
      }
      hard_delete_unused_custom_grape_variety: {
        Args: { p_variety_id: string }
        Returns: Json
      }
      hard_delete_unused_saved_chemical: {
        Args: { p_id: string }
        Returns: Json
      }
      hard_delete_vintage_note: {
        Args: {
          p_deleted_at?: string
          p_note_id: string
          p_operation_id: string
          p_vineyard_id: string
        }
        Returns: boolean
      }
      has_any_vineyard_membership: { Args: never; Returns: boolean }
      has_irrigation_records_access: {
        Args: { p_vineyard_id: string }
        Returns: boolean
      }
      has_mait_intelliweb_access: {
        Args: { p_vineyard_id: string }
        Returns: boolean
      }
      has_mait_intelliweb_manage_access: {
        Args: { p_vineyard_id: string }
        Returns: boolean
      }
      has_mait_intelliweb_view_access: {
        Args: { p_vineyard_id: string }
        Returns: boolean
      }
      has_vineyard_role: {
        Args: { allowed_roles: string[]; p_vineyard_id: string }
        Returns: boolean
      }
      insert_pin_capture_evidence: {
        Args: { p_payload: Json }
        Returns: string
      }
      integration_api_create_fuel_record: {
        Args: {
          p_idempotency_key: string
          p_payload: Json
          p_presented_key: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      integration_api_create_grape_allocation: {
        Args: {
          p_idempotency_key: string
          p_payload: Json
          p_presented_key: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      integration_api_create_grape_purchaser: {
        Args: {
          p_idempotency_key: string
          p_payload: Json
          p_presented_key: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      integration_api_create_growth_stage: {
        Args: {
          p_idempotency_key: string
          p_payload: Json
          p_presented_key: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      integration_api_create_irrigation_record: {
        Args: {
          p_idempotency_key: string
          p_payload: Json
          p_presented_key: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      integration_api_create_work_task: {
        Args: {
          p_idempotency_key: string
          p_payload: Json
          p_presented_key: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      integration_api_create_yield_record: {
        Args: {
          p_idempotency_key: string
          p_payload: Json
          p_presented_key: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      integration_api_update_fuel_record: {
        Args: {
          p_fuel_record_id: string
          p_payload: Json
          p_presented_key: string
        }
        Returns: Json
      }
      integration_api_update_grape_allocation: {
        Args: {
          p_grape_allocation_id: string
          p_payload: Json
          p_presented_key: string
        }
        Returns: Json
      }
      integration_api_update_grape_purchaser: {
        Args: {
          p_grape_purchaser_id: string
          p_payload: Json
          p_presented_key: string
        }
        Returns: Json
      }
      integration_api_update_work_task: {
        Args: {
          p_payload: Json
          p_presented_key: string
          p_work_task_id: string
        }
        Returns: Json
      }
      integration_api_update_yield_record: {
        Args: {
          p_payload: Json
          p_presented_key: string
          p_yield_record_id: string
        }
        Returns: Json
      }
      integration_audit_history: {
        Args: { p_client_id: string; p_limit?: number }
        Returns: Json
      }
      integration_authenticate_api_key: {
        Args: { p_presented_key: string }
        Returns: Json
      }
      integration_check_rate_limit: {
        Args: { p_api_key_id: string; p_limit?: number }
        Returns: Json
      }
      integration_create_api_key: {
        Args: {
          p_client_id: string
          p_environment?: string
          p_expires_at?: string
          p_name?: string
        }
        Returns: Json
      }
      integration_create_client: {
        Args: {
          p_description?: string
          p_integration_type: string
          p_name: string
        }
        Returns: Json
      }
      integration_create_webhook_endpoint: {
        Args: { p_client_id: string; p_name?: string; p_url: string }
        Returns: Json
      }
      integration_create_webhook_subscription: {
        Args: {
          p_endpoint_id: string
          p_event_type: string
          p_vineyard_id?: string
        }
        Returns: Json
      }
      integration_delete_webhook_endpoint: {
        Args: { p_endpoint_id: string }
        Returns: undefined
      }
      integration_delete_webhook_subscription: {
        Args: { p_subscription_id: string }
        Returns: undefined
      }
      integration_get_rainfall: {
        Args: {
          p_before?: string
          p_from?: string
          p_limit?: number
          p_to?: string
          p_vineyard_id: string
        }
        Returns: {
          date: string
          notes: string
          rainfall_mm: number
          source: string
          station_id: string
          station_name: string
          updated_at: string
        }[]
      }
      integration_get_webhook_delivery: {
        Args: { p_delivery_id: string }
        Returns: Json
      }
      integration_get_webhook_endpoint: {
        Args: { p_endpoint_id: string }
        Returns: Json
      }
      integration_grant_scope: {
        Args: { p_client_id: string; p_scope: string }
        Returns: Json
      }
      integration_grant_vineyard: {
        Args: { p_client_id: string; p_vineyard_id: string }
        Returns: Json
      }
      integration_list_api_keys: {
        Args: { p_client_id: string }
        Returns: Json
      }
      integration_list_api_requests: {
        Args: {
          p_api_key_id?: string
          p_before_created_at?: string
          p_before_id?: string
          p_client_id: string
          p_error_only?: boolean
          p_from?: string
          p_limit?: number
          p_status_code?: number
          p_to?: string
          p_vineyard_id?: string
        }
        Returns: Json
      }
      integration_list_clients: { Args: never; Returns: Json }
      integration_list_scopes: { Args: { p_client_id: string }; Returns: Json }
      integration_list_vineyard_grants: {
        Args: { p_client_id: string }
        Returns: Json
      }
      integration_list_webhook_deliveries: {
        Args: {
          p_before_created_at?: string
          p_before_id?: string
          p_client_id: string
          p_endpoint_id?: string
          p_event_type?: string
          p_from?: string
          p_limit?: number
          p_status?: string
          p_to?: string
          p_vineyard_id?: string
        }
        Returns: Json
      }
      integration_list_webhook_endpoints: {
        Args: { p_client_id: string }
        Returns: Json
      }
      integration_list_webhook_subscriptions: {
        Args: { p_endpoint_id: string }
        Returns: Json
      }
      integration_log_api_request: {
        Args: {
          p_api_key_id: string
          p_duration_ms: number
          p_error_code: string
          p_integration_client_id: string
          p_method: string
          p_path: string
          p_request_id: string
          p_status_code: number
          p_vineyard_id: string
        }
        Returns: undefined
      }
      integration_replay_webhook_delivery: {
        Args: { p_delivery_id: string }
        Returns: Json
      }
      integration_revoke_api_key: {
        Args: { p_client_id: string; p_key_id: string }
        Returns: Json
      }
      integration_revoke_scope: {
        Args: { p_client_id: string; p_scope: string }
        Returns: Json
      }
      integration_revoke_vineyard: {
        Args: { p_client_id: string; p_vineyard_id: string }
        Returns: Json
      }
      integration_rotate_webhook_secret: {
        Args: { p_endpoint_id: string }
        Returns: Json
      }
      integration_send_test_webhook: {
        Args: { p_endpoint_id: string }
        Returns: Json
      }
      integration_set_status: {
        Args: { p_action: string; p_client_id: string }
        Returns: Json
      }
      integration_set_webhook_endpoint_status: {
        Args: { p_endpoint_id: string; p_status: string }
        Returns: Json
      }
      integration_update_client: {
        Args: { p_client_id: string; p_description?: string; p_name?: string }
        Returns: Json
      }
      integration_update_webhook_endpoint: {
        Args: { p_endpoint_id: string; p_name?: string; p_url?: string }
        Returns: Json
      }
      integration_validate_api_request: {
        Args: {
          p_presented_key: string
          p_required_scope: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      integration_webhook_claim_deliveries: {
        Args: { p_batch?: number; p_lease_seconds?: number }
        Returns: Json
      }
      integration_webhook_get_endpoint_secret: {
        Args: { p_endpoint_id: string }
        Returns: string
      }
      integration_webhook_record_attempt: {
        Args: {
          p_claim_token: string
          p_delivery_id: string
          p_duration_ms?: number
          p_error_category?: string
          p_error_detail?: string
          p_http_status?: number
          p_outcome: string
          p_retry_after_seconds?: number
        }
        Returns: Json
      }
      irrigation_capability: {
        Args: { p_capability: string; p_vineyard_id: string }
        Returns: boolean
      }
      irrigation_total_volume: {
        Args: {
          p_duration_minutes: number
          p_flow_litres_per_hour: number
          p_meter_finish_litres: number
          p_meter_start_litres: number
          p_method: string
          p_total_volume_litres: number
        }
        Returns: number
      }
      is_admin: { Args: never; Returns: boolean }
      is_system_admin: { Args: never; Returns: boolean }
      is_vineyard_member: { Args: { p_vineyard_id: string }; Returns: boolean }
      is_vineyard_owner_or_manager: {
        Args: { p_vineyard_id: string }
        Returns: boolean
      }
      list_fertigation_applications: {
        Args: {
          p_include_reversed?: boolean
          p_program_step_id?: string
          p_vineyard_id: string
          p_vintage_year?: number
        }
        Returns: Json
      }
      list_fertigation_program_steps: {
        Args: { p_vineyard_id: string }
        Returns: Json
      }
      list_irrigation_available_rows: {
        Args: { p_block_id?: string; p_vineyard_id: string }
        Returns: Json
      }
      list_irrigation_import_batches: {
        Args: {
          p_limit?: number
          p_offset?: number
          p_provider?: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      list_irrigation_import_providers: { Args: never; Returns: Json }
      list_irrigation_import_rows: {
        Args: {
          p_batch_id: string
          p_classification?: string
          p_include_raw?: boolean
          p_limit?: number
          p_offset?: number
          p_validation_status?: string
        }
        Returns: Json
      }
      list_irrigation_import_valves: {
        Args: { p_batch_id: string }
        Returns: Json
      }
      list_irrigation_report_sessions: {
        Args: {
          p_block_id?: string
          p_calculation_method?: string
          p_date_from?: string
          p_date_to?: string
          p_include_estimated?: boolean
          p_include_imported?: boolean
          p_include_reversed?: boolean
          p_limit?: number
          p_measurement_group?: string
          p_offset?: number
          p_source_group?: string
          p_source_type?: string
          p_system_id?: string
          p_valve_id?: string
          p_variety_id?: string
          p_vineyard_id: string
          p_vintage_year?: number
          p_water_source?: string
        }
        Returns: Json
      }
      list_irrigation_sessions: {
        Args: {
          p_block_id?: string
          p_from_date?: string
          p_include_reversed?: boolean
          p_irrigation_system_id?: string
          p_limit?: number
          p_offset?: number
          p_source_type?: string
          p_status?: string
          p_to_date?: string
          p_valve_id?: string
          p_vineyard_id: string
          p_vintage_year?: number
        }
        Returns: Json
      }
      list_irrigation_systems: {
        Args: { p_include_inactive?: boolean; p_vineyard_id: string }
        Returns: Json
      }
      list_irrigation_valve_blocks: {
        Args: { p_valve_id?: string; p_vineyard_id: string }
        Returns: Json
      }
      list_irrigation_valve_rows: {
        Args: { p_valve_id?: string; p_vineyard_id: string }
        Returns: Json
      }
      list_irrigation_valves: {
        Args: { p_include_inactive?: boolean; p_vineyard_id: string }
        Returns: Json
      }
      list_manual_issues: {
        Args: {
          p_include_deleted?: boolean
          p_paddock_id?: string
          p_statuses?: string[]
          p_vineyard_id: string
        }
        Returns: Json
      }
      list_my_pending_invitations: {
        Args: never
        Returns: {
          created_at: string
          email: string
          expires_at: string
          id: string
          invited_by_name: string
          role: string
          status: string
          vineyard_country: string
          vineyard_id: string
          vineyard_name: string
        }[]
      }
      list_pruning_activities: {
        Args: {
          p_from?: string
          p_include_reversed?: boolean
          p_limit?: number
          p_offset?: number
          p_to?: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      list_system_admins: {
        Args: never
        Returns: {
          created_at: string
          created_by: string
          email: string
          is_active: boolean
          user_id: string
        }[]
      }
      list_vineyard_custom_pin_types: {
        Args: { p_include_inactive?: boolean; p_vineyard_id: string }
        Returns: Json
      }
      list_vineyard_grape_clones: {
        Args: { p_vineyard_id: string }
        Returns: {
          clone_key: string
          created_at: string
          display_name: string
          id: string
          is_active: boolean
          is_custom: boolean
          updated_at: string
          variety_key: string
          vineyard_id: string
        }[]
      }
      list_vineyard_grape_varieties: {
        Args: { p_vineyard_id: string }
        Returns: {
          created_at: string
          display_name: string
          id: string
          is_active: boolean
          is_custom: boolean
          optimal_gdd_override: number
          updated_at: string
          variety_key: string
          vineyard_id: string
        }[]
      }
      list_vineyard_invitations: {
        Args: { p_vineyard_id: string }
        Returns: {
          created_at: string
          email: string
          expires_at: string | null
          id: string
          invited_by: string | null
          role: string
          status: string
          updated_at: string
          vineyard_id: string
          worker_type_id: string | null
        }[]
        SetofOptions: {
          from: "*"
          to: "invitations"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      list_vineyard_rootstocks: {
        Args: { p_vineyard_id: string }
        Returns: {
          created_at: string
          display_name: string
          id: string
          is_active: boolean
          is_custom: boolean
          rootstock_key: string
          updated_at: string
          vineyard_id: string
        }[]
      }
      list_vineyard_soil_profiles: {
        Args: { p_vineyard_id: string }
        Returns: {
          australian_soil_classification: string | null
          australian_soil_classification_code: string | null
          available_water_capacity_mm_per_m: number | null
          confidence: string | null
          country_code: string | null
          created_at: string
          drainage_risk: string | null
          effective_root_depth_m: number | null
          id: string
          infiltration_risk: string | null
          irrigation_soil_class: string | null
          is_manual_override: boolean
          land_soil_capability: string | null
          land_soil_capability_class: number | null
          lookup_latitude: number | null
          lookup_longitude: number | null
          management_allowed_depletion_percent: number | null
          manual_notes: string | null
          model_version: string
          paddock_id: string | null
          raw_source_json: Json | null
          region_code: string | null
          soil_description: string | null
          soil_landscape: string | null
          soil_landscape_code: string | null
          soil_texture_class: string | null
          source: string
          source_dataset: string | null
          source_feature_id: string | null
          source_name: string | null
          source_provider: string | null
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          waterlogging_risk: string | null
        }[]
        SetofOptions: {
          from: "*"
          to: "paddock_soil_profiles"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      list_vineyard_spray_targets: {
        Args: { p_include_inactive?: boolean; p_vineyard_id: string }
        Returns: Json[]
      }
      manual_issue_json: {
        Args: { p_pin: Database["public"]["Tables"]["pins"]["Row"] }
        Returns: Json
      }
      manual_spray_compatible_tanks_v1: {
        Args: { p_tanks: Json }
        Returns: Json
      }
      manual_spray_number_v1: {
        Args: { p_field: string; p_required?: boolean; p_value: Json }
        Returns: number
      }
      mark_vineyard_alert_status: {
        Args: { p_alert_id: string; p_dismissed?: boolean; p_read?: boolean }
        Returns: undefined
      }
      master_backfill_catalogue_stats_v2: { Args: never; Returns: Json }
      master_chemical_has_viticulture_evidence: {
        Args: { m: Database["public"]["Tables"]["master_chemicals"]["Row"] }
        Returns: boolean
      }
      master_chemical_is_v2_eligible: {
        Args: { m: Database["public"]["Tables"]["master_chemicals"]["Row"] }
        Returns: boolean
      }
      master_review_adjudicate: {
        Args: {
          p_conflict: Json
          p_expected_revision: number
          p_field: string
          p_master_id: string
          p_reason: string
          p_selected: string
        }
        Returns: Json
      }
      master_review_apply: {
        Args: { p_master_id: string; p_preview_id: string; p_reason: string }
        Returns: Json
      }
      master_review_correct: {
        Args: {
          p_expected_revision: number
          p_master_id: string
          p_patch: Json
          p_reason: string
        }
        Returns: Json
      }
      master_review_rekey: {
        Args: {
          p_expected_revision: number
          p_master_id: string
          p_new_country: string
          p_new_number: string
          p_new_scheme: string
          p_reason: string
        }
        Returns: Json
      }
      merge_operator_categories: {
        Args: { p_source_id: string; p_target_id: string }
        Returns: Json
      }
      merge_worker_types: {
        Args: { p_source_id: string; p_target_id: string }
        Returns: Json
      }
      operator_category_normalised_name: {
        Args: { p_name: string }
        Returns: string
      }
      paddock_reference_counts: {
        Args: { p_paddock_id: string }
        Returns: {
          damage_records: number
          growth_stage_records: number
          paddock_soil_profiles: number
          pins: number
          spray_job_paddocks: number
          total_references: number
          trip_cost_allocations: number
          trips: number
          work_task_paddocks: number
          work_tasks: number
        }[]
      }
      pin_capture_course_direction: {
        Args: {
          captured_at: string
          minimum_agreement?: number
          observations: Json
        }
        Returns: Json
      }
      pin_geometry_identity: {
        Args: { points: Json; rows: Json }
        Returns: string
      }
      pin_location_placement_json: {
        Args: { p: Database["public"]["Tables"]["pins"]["Row"] }
        Returns: Json
      }
      pin_point_in_polygon: {
        Args: { lat: number; lon: number; points: Json }
        Returns: boolean
      }
      pin_row_backfill_apply: {
        Args: { p_approval: string; p_confirm: string; p_items_hash: string }
        Returns: Json
      }
      pin_row_backfill_create_approval: {
        Args: { p_items: Json; p_vineyard: string }
        Returns: Json
      }
      pin_row_backfill_dry_run: {
        Args: { p_items: Json; p_vineyard: string }
        Returns: Json
      }
      pin_row_reconstruction_report: {
        Args: { p_vineyard: string }
        Returns: Json
      }
      pin_row_selection_summary: { Args: { p_segments: Json }; Returns: string }
      plan_wunderground_rainfall_backfill: {
        Args: { p_days?: number; p_timezone?: string; p_vineyard_id: string }
        Returns: {
          dates_already_wu: string[]
          dates_skipped_davis: string[]
          dates_skipped_manual: string[]
          dates_skipped_today: string[]
          dates_to_fetch: string[]
          days_requested: number
          station_id: string
          station_name: string
          timezone: string
          today_local: string
          vineyard_id: string
        }[]
      }
      planting_group_key: {
        Args: { p_clone: string; p_rootstock: string; p_variety: string }
        Returns: string
      }
      portal_archive_tractor: {
        Args: { p_tractor_id: string }
        Returns: {
          archived_at: string
          machine_id: string
          tractor_id: string
        }[]
      }
      portal_upsert_tractor: {
        Args: {
          p_brand?: string
          p_client_updated_at?: string
          p_fuel_usage_l_per_hour?: number
          p_model?: string
          p_model_year?: number
          p_name?: string
          p_serial_number?: string
          p_tractor_id?: string
          p_vin_number?: string
          p_vineyard_id: string
        }
        Returns: {
          available_for_job_costing: boolean
          brand: string
          fuel_tracking_enabled: boolean
          fuel_usage_l_per_hour: number
          machine_id: string
          machine_type: string
          mirror_was_created: boolean
          model: string
          model_year: number
          name: string
          serial_number: string
          tractor_id: string
          updated_at: string
          vin_number: string
          vineyard_id: string
          was_created: boolean
        }[]
      }
      preview_irrigation_import: { Args: { p_batch_id: string }; Returns: Json }
      prune_stale_user_clients: {
        Args: { p_older_than?: string }
        Returns: number
      }
      pruning_activity_effective_labour_cost: {
        Args: { p_activity_id: string }
        Returns: number
      }
      pruning_activity_effective_labour_hours: {
        Args: { p_activity_id: string }
        Returns: number
      }
      pruning_activity_json: {
        Args: { p_activity_id: string; p_include_segments?: boolean }
        Returns: Json
      }
      pruning_activity_labour_cost_source: {
        Args: { p_activity_id: string }
        Returns: string
      }
      pruning_activity_labour_hours_source: {
        Args: { p_activity_id: string }
        Returns: string
      }
      pruning_activity_labour_line_cost: {
        Args: { p_activity_id: string }
        Returns: number
      }
      pruning_activity_labour_line_count: {
        Args: { p_activity_id: string }
        Returns: number
      }
      pruning_activity_labour_line_hours: {
        Args: { p_activity_id: string }
        Returns: number
      }
      pruning_activity_labour_lines_json: {
        Args: { p_activity_id: string }
        Returns: Json
      }
      pruning_activity_work_task_count: {
        Args: { p_activity_id: string }
        Returns: number
      }
      pruning_activity_work_task_ids: {
        Args: { p_activity_id: string }
        Returns: string[]
      }
      pruning_activity_work_tasks_labour_cost: {
        Args: { p_activity_id: string }
        Returns: number
      }
      pruning_activity_work_tasks_labour_hours: {
        Args: { p_activity_id: string }
        Returns: number
      }
      record_irrigation_session: {
        Args: {
          p_calculation_method: string
          p_duration_minutes: number
          p_finished_at?: string
          p_flow_litres_per_hour?: number
          p_id: string
          p_irrigation_system_id: string
          p_meter_finish_litres?: number
          p_meter_start_litres?: number
          p_notes?: string
          p_original_unit?: string
          p_original_value?: number
          p_session_date: string
          p_source_type?: string
          p_started_at?: string
          p_total_volume_litres?: number
          p_valve_id: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      record_my_client_activity: {
        Args: {
          p_app_build: string
          p_app_type: string
          p_app_version: string
          p_browser_name?: string
          p_browser_version?: string
          p_client_instance_id: string
          p_device_family: string
          p_device_model: string
          p_os_name: string
          p_os_version: string
          p_platform: string
          p_vineyard_id?: string
        }
        Returns: Json
      }
      record_pruning_activity:
        | {
            Args: {
              p_activity: Json
              p_activity_id: string
              p_allocations: Json
              p_client_updated_at?: string
              p_vineyard_id: string
            }
            Returns: Json
          }
        | { Args: { p_payload: Json }; Returns: Json }
      record_pruning_entry: {
        Args: {
          p_client_updated_at?: string
          p_entry_date: string
          p_estimated_vines?: number
          p_finish_time?: string
          p_id: string
          p_labour_hours?: number
          p_method?: string
          p_notes?: string
          p_paddock_id: string
          p_season_id: string
          p_season_year: number
          p_segments?: Json
          p_start_time?: string
          p_vineyard_id: string
          p_vintage_year?: number
          p_work_task_id?: string
          p_worker: string
        }
        Returns: Json
      }
      record_skipped_pruning_entry: {
        Args: {
          p_client_updated_at?: string
          p_entry_date: string
          p_id: string
          p_notes?: string
          p_paddock_id: string
          p_season_id: string
          p_season_year: number
          p_segments?: Json
          p_vineyard_id: string
        }
        Returns: Json
      }
      record_trip_weather_observation_v2:
        | {
            Args: {
              p_humidity_pct: number
              p_is_stale: boolean
              p_observed_at: string
              p_provider_record_id: string
              p_rain_mm: number
              p_retrieval_mode: string
              p_sample_slot: string
              p_source: string
              p_source_kind: string
              p_station_id: string
              p_temperature_c: number
              p_trip_id: string
              p_wind_direction_deg: number
              p_wind_gust_kmh: number
              p_wind_speed_kmh: number
            }
            Returns: {
              captured_at: string
              humidity_pct: number | null
              id: string
              is_stale: boolean
              observed_at: string | null
              provider: string | null
              provider_record_id: string | null
              rain_mm: number | null
              retrieval_mode: string
              retrieved_at: string
              sample_slot: string
              source: string
              source_kind: string
              station_id: string | null
              station_name: string | null
              temperature_c: number | null
              trip_id: string
              vineyard_id: string
              wind_direction_deg: number | null
              wind_gust_kmh: number | null
              wind_speed_kmh: number | null
            }
            SetofOptions: {
              from: "*"
              to: "trip_weather_observations"
              isOneToOne: true
              isSetofReturn: false
            }
          }
        | {
            Args: {
              p_humidity_pct: number
              p_is_stale: boolean
              p_observed_at: string
              p_provider?: string
              p_provider_record_id: string
              p_rain_mm: number
              p_retrieval_mode: string
              p_sample_slot: string
              p_source: string
              p_source_kind: string
              p_station_id: string
              p_station_name?: string
              p_temperature_c: number
              p_trip_id: string
              p_wind_direction_deg: number
              p_wind_gust_kmh: number
              p_wind_speed_kmh: number
            }
            Returns: {
              captured_at: string
              humidity_pct: number | null
              id: string
              is_stale: boolean
              observed_at: string | null
              provider: string | null
              provider_record_id: string | null
              rain_mm: number | null
              retrieval_mode: string
              retrieved_at: string
              sample_slot: string
              source: string
              source_kind: string
              station_id: string | null
              station_name: string | null
              temperature_c: number | null
              trip_id: string
              vineyard_id: string
              wind_direction_deg: number | null
              wind_gust_kmh: number | null
              wind_speed_kmh: number | null
            }
            SetofOptions: {
              from: "*"
              to: "trip_weather_observations"
              isOneToOne: true
              isSetofReturn: false
            }
          }
      record_trip_weather_retrieval_attempt_v1: {
        Args: {
          p_outcome: string
          p_provider: string
          p_retrieval_mode: string
          p_sample_slot: string
          p_source?: string
          p_station_id: string
          p_station_name: string
          p_trip_id: string
        }
        Returns: string
      }
      recover_legacy_spray_pair_v1: {
        Args: { p_operation_id: string; p_record: Json; p_trip: Json }
        Returns: Json
      }
      recover_spray_row_assignments_v1: {
        Args: {
          p_actor_user_id: string
          p_assignments: Json
          p_operation_id: string
          p_trip_id: string
        }
        Returns: Json
      }
      recover_spray_row_assignments_v2: {
        Args: {
          p_actor_user_id: string
          p_assignments: Json
          p_operation_id: string
          p_trip_id: string
        }
        Returns: Json
      }
      refresh_pruning_yield_estimates: {
        Args: { p_vineyard_id: string; p_vintage: number }
        Returns: Json
      }
      register_spray_report_route_asset_v1: {
        Args: {
          p_bucket: string
          p_object_path: string
          p_route_hash: string
          p_sha256: string
          p_style_version: string
          p_trip_id: string
        }
        Returns: Json
      }
      reject_chemical_v3_revision: {
        Args: { p_note?: string; p_revision_id: string }
        Returns: string
      }
      remove_axisstream_exchange_configuration: {
        Args: { p_vineyard_id: string }
        Returns: undefined
      }
      remove_mait_intelliweb_connection: {
        Args: { p_vineyard_id: string }
        Returns: undefined
      }
      remove_mait_intelliweb_sensor_module: {
        Args: { p_module_id: string; p_vineyard_id: string }
        Returns: undefined
      }
      remove_member:
        | { Args: { p_membership_id: string }; Returns: Json }
        | { Args: { p_user_id: string; p_vineyard_id: string }; Returns: Json }
      remove_system_admin: {
        Args: { p_user_id: string }
        Returns: {
          created_at: string
          created_by: string
          email: string
          is_active: boolean
          user_id: string
        }[]
      }
      remove_vineyard_wunderground_station: {
        Args: { p_vineyard_id: string }
        Returns: boolean
      }
      repair_grape_variety_allocation_by_mapping: {
        Args: {
          p_catalog_key: string
          p_dry_run?: boolean
          p_old_variety_id: string
          p_vineyard_id: string
        }
        Returns: {
          allocations_changed: number
          new_variety_id: string
          new_variety_name: string
          paddocks_changed: number
          vineyard_id: string
        }[]
      }
      repair_grape_variety_allocations: {
        Args: { p_dry_run?: boolean; p_vineyard_id?: string }
        Returns: {
          allocations_checked: number
          allocations_repaired: number
          duplicates_collapsed: number
          names_backfilled: number
          paddocks_checked: number
          unresolved_allocations: number
          vineyard_id: string
        }[]
      }
      repair_grape_variety_allocations_admin: {
        Args: { p_dry_run?: boolean; p_vineyard_id?: string }
        Returns: {
          allocations_checked: number
          allocations_repaired: number
          duplicates_collapsed: number
          names_backfilled: number
          paddocks_checked: number
          unresolved_allocations: number
          vineyard_id: string
        }[]
      }
      repair_pruning_entry_seasons: {
        Args: {
          p_dry_run?: boolean
          p_entry_ids?: string[]
          p_include_reversed?: boolean
          p_vineyard_id?: string
        }
        Returns: {
          action: string
          block_name: string
          entry_date: string
          entry_id: string
          new_season_id: string
          new_season_year: number
          note: string
          old_season_id: string
          old_season_year: number
          quarters: number
          rows_covered: string
          vineyard_name: string
          vintage_year: number
        }[]
      }
      report_entitlement_mismatch: {
        Args: { p_app_version?: string; p_detail?: Json; p_platform: string }
        Returns: undefined
      }
      report_unresolved_grape_variety_allocations: {
        Args: { p_vineyard_id?: string }
        Returns: {
          allocation_id: string
          allocation_name: string
          paddock_id: string
          paddock_name: string
          percent: number
          reason: string
          variety_id: string
          variety_key: string
          vineyard_id: string
          vineyard_name: string
        }[]
      }
      resend_invitation:
        | {
            Args: { p_expires_at?: string; p_invitation_id: string }
            Returns: {
              created_at: string
              email: string
              expires_at: string | null
              id: string
              invited_by: string | null
              role: string
              status: string
              updated_at: string
              vineyard_id: string
              worker_type_id: string | null
            }[]
            SetofOptions: {
              from: "*"
              to: "invitations"
              isOneToOne: false
              isSetofReturn: true
            }
          }
        | {
            Args: { p_extend_days?: number; p_invitation_id: string }
            Returns: {
              created_at: string
              email: string
              expires_at: string | null
              id: string
              invited_by: string | null
              role: string
              status: string
              updated_at: string
              vineyard_id: string
              worker_type_id: string | null
            }
            SetofOptions: {
              from: "*"
              to: "invitations"
              isOneToOne: true
              isSetofReturn: false
            }
          }
      reset_my_operational_tool_preferences: { Args: never; Returns: Json }
      resistance_plan_block_ids_are_valid: {
        Args: { p_ids: string[] }
        Returns: boolean
      }
      resistance_plan_positions_are_valid: {
        Args: { p_positions: Json }
        Returns: boolean
      }
      resistance_position_coverage: {
        Args: { p_plan_id: string; p_position_id: string }
        Returns: {
          completed_block_ids: string[]
          proposed_paddock_ids: string[]
          spray_job_count: number
        }[]
      }
      resistance_position_spray_job_ids: {
        Args: { p_plan_id: string; p_position_id: string }
        Returns: string[]
      }
      resolve_pin_placement: { Args: { p_pin_id: string }; Returns: Json }
      resolve_pin_row_geometry:
        | {
            Args: {
              accuracy_m: number
              heading: number
              lat: number
              lon: number
              pressed_side: string
              rows: Json
            }
            Returns: Json
          }
        | {
            Args: {
              accuracy_m: number
              aisle_lock: Json
              captured_at: string
              heading: number
              heading_observed_at: string
              lat: number
              lon: number
              observations: Json
              paddock_id: string
              polygon: Json
              pressed_side: string
              row_width: number
              rows: Json
            }
            Returns: Json
          }
      resolve_pruning_allocation_id: {
        Args: {
          p_activity_id: string
          p_paddock_id: string
          p_supplied?: string
        }
        Returns: Json
      }
      resolve_pruning_season: {
        Args: {
          p_client_updated_at?: string
          p_entry_date: string
          p_paddock_id: string
          p_season_id?: string
          p_vineyard_id: string
        }
        Returns: string
      }
      resolve_pruning_season_for_date: {
        Args: {
          p_client_updated_at?: string
          p_create_missing?: boolean
          p_entry_date: string
          p_paddock_id: string
          p_season_id?: string
          p_vineyard_id: string
        }
        Returns: string
      }
      resolve_vineyard_vintage_year: {
        Args: { p_record_date: string; p_vineyard_id: string }
        Returns: number
      }
      resolve_vintage_year: {
        Args: {
          p_record_date: string
          p_start_day: number
          p_start_month: number
        }
        Returns: number
      }
      resolve_yield_bunch_weight: {
        Args: {
          p_paddock_id: string
          p_variety_key: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      restore_paddock: { Args: { p_paddock_id: string }; Returns: undefined }
      restore_resistance_plan: { Args: { p_id: string }; Returns: undefined }
      restore_spray_job: { Args: { p_id: string }; Returns: undefined }
      restore_vineyard_trip_function: {
        Args: { p_id: string }
        Returns: undefined
      }
      reveal_vineyard_weather_integration_credentials: {
        Args: { p_provider?: string; p_vineyard_id: string }
        Returns: {
          api_key: string
          api_secret: string
        }[]
      }
      reverse_fertigation_application: {
        Args: { p_id: string; p_reason?: string }
        Returns: Json
      }
      reverse_irrigation_import_batch: {
        Args: { p_batch_id: string; p_dry_run?: boolean }
        Returns: Json
      }
      reverse_irrigation_session: { Args: { p_id: string }; Returns: Json }
      reverse_pin_location_enrichment: {
        Args: { p_audit_id: string }
        Returns: string
      }
      reverse_pruning_activity: {
        Args: { p_activity_id: string; p_reason?: string }
        Returns: Json
      }
      save_axisstream_exchange_configuration: {
        Args: {
          p_leaf_code?: string
          p_mode?: string
          p_rain_code?: string
          p_token?: string
          p_vineyard_id: string
          p_weather_code?: string
        }
        Returns: Json
      }
      save_contour_row_mapping_draft: {
        Args: {
          p_client_save_id: string
          p_expected_draft_id: string
          p_expected_revision: number
          p_paddock_id: string
          p_payload: Json
        }
        Returns: Json
      }
      save_legacy_spray_pair_v1: {
        Args: { p_operation_id: string; p_record: Json; p_trip: Json }
        Returns: Json
      }
      save_mait_intelliweb_channel_mapping: {
        Args: {
          p_canonical_metric: string
          p_channel_key: string
          p_channel_number?: number
          p_conversion_multiplier?: number
          p_conversion_offset?: number
          p_is_active?: boolean
          p_module_id: string
          p_semantics?: string
          p_source_label?: string
          p_source_unit?: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      save_mait_intelliweb_connection: {
        Args: {
          p_network_id: string
          p_network_name?: string
          p_password?: string
          p_timezone?: string
          p_username: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      save_mait_intelliweb_sensor_channel_mapping: {
        Args: {
          p_canonical_metric: string
          p_channel_key: string
          p_channel_number?: number
          p_conversion_multiplier?: number
          p_conversion_offset?: number
          p_is_active?: boolean
          p_module_id: string
          p_semantics?: string
          p_source_label?: string
          p_source_unit?: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      save_manual_spray_v1: {
        Args: {
          p_expected_version?: number
          p_operation_id: string
          p_payload: Json
        }
        Returns: Json
      }
      save_manual_spray_v1_pre_edit_correction_v1: {
        Args: {
          p_expected_version?: number
          p_operation_id: string
          p_payload: Json
        }
        Returns: Json
      }
      save_pruning_activity_labour_lines: {
        Args: {
          p_activity_id: string
          p_client_updated_at?: string
          p_lines: Json
        }
        Returns: Json
      }
      save_spray_trip_worksheet_v1: {
        Args: {
          p_metadata?: Json
          p_operation_id: string
          p_tanks?: Json
          p_trip_id: string
        }
        Returns: Json
      }
      save_vineyard_weather_integration: {
        Args: {
          p_api_key?: string
          p_api_secret?: string
          p_detected_sensors?: string[]
          p_has_leaf_wetness?: boolean
          p_has_rain?: boolean
          p_has_temperature_humidity?: boolean
          p_has_wind?: boolean
          p_is_active?: boolean
          p_last_test_status?: string
          p_last_tested_at?: string
          p_provider: string
          p_station_id?: string
          p_station_latitude?: number
          p_station_longitude?: number
          p_station_name?: string
          p_vineyard_id: string
        }
        Returns: string
      }
      save_vineyard_wunderground_station: {
        Args: {
          p_station_id: string
          p_station_latitude?: number
          p_station_longitude?: number
          p_station_name?: string
          p_vineyard_id: string
        }
        Returns: string
      }
      search_chemical_v3_catalogue: {
        Args: { p_country_code?: string; p_limit?: number; p_query: string }
        Returns: {
          active_ingredients: Json
          activity_group_scheme: string
          activity_groups: string[]
          core_fields_complete: boolean
          country_code: string
          default_rate_options: Json
          freshness_status: string
          front_label_image_path: string
          last_verified_at: string
          manufacturer: string
          manufacturer_label_url: string
          product_category: string
          product_category_key: string
          product_category_label: string
          product_form: string
          product_id: string
          product_name: string
          refresh_recommended: boolean
          registration_number: string
          registration_scheme: string
          resistance_classification_state: string
          resistance_group_source: string
          review_status: string
          revision_id: string
          vineyard_rate_status: string
        }[]
      }
      search_master_chemicals_v2: {
        Args: { p_limit?: number; p_query: string }
        Returns: {
          active_ingredients: Json
          activity_group_scheme: string
          activity_groups: string[]
          catalogue_version: number
          common_names: string[]
          form_type: string
          has_viticulture_evidence: boolean
          id: string
          label_rate_bases: string[]
          label_reference: string
          label_version: string
          manufacturer_label_url: string
          manufacturer_product_url: string
          product_category: string
          registered_product_name: string
          registered_uses: Json
          registrant: string
          registration_country: string
          registration_number: string
          registration_scheme: string
          regulator_label_url: string
          resistance_classification_state: string
          review_status: string
          search_rank: number
          source_kind: string
          verification_conflicts: Json
          verification_sources: Json
          verification_status: string
          verification_unresolved_fields: string[]
          verified_at: string
          viticulture_rates: Json
        }[]
      }
      season_yield_estimate_source_rank: {
        Args: { p_source: string }
        Returns: number
      }
      set_default_vineyard: {
        Args: { p_vineyard_id: string }
        Returns: undefined
      }
      set_irrigation_controller_valve_mapping: {
        Args: {
          p_confirm_change?: boolean
          p_external_controller_key: string
          p_external_controller_name?: string
          p_external_station_code?: string
          p_external_valve_name: string
          p_external_valve_number?: number
          p_ignore?: boolean
          p_irrigation_valve_id?: string
          p_provider: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      set_irrigation_import_provider_settings: {
        Args: {
          p_exclude_test_programs?: boolean
          p_external_controller_key?: string
          p_external_controller_name?: string
          p_minimum_volume_litres?: number
          p_provider: string
          p_timezone?: string
          p_vineyard_id: string
          p_volume_comparison?: string
        }
        Returns: Json
      }
      set_irrigation_import_row_override: {
        Args: {
          p_override_test?: boolean
          p_override_threshold?: boolean
          p_reason?: string
          p_row_id: string
        }
        Returns: Json
      }
      set_irrigation_valve_blocks: {
        Args: { p_blocks: Json; p_valve_id: string; p_vineyard_id: string }
        Returns: Json
      }
      set_irrigation_valve_rows: {
        Args: { p_row_ids: string[]; p_valve_id: string; p_vineyard_id: string }
        Returns: Json
      }
      set_mait_intelliweb_controller_module: {
        Args: {
          p_irrigation_system_id: string
          p_module_id: string
          p_module_name?: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      set_mait_intelliweb_rainfall_publish_enabled: {
        Args: { p_enabled: boolean; p_vineyard_id: string }
        Returns: Json
      }
      set_mait_intelliweb_sensor_module: {
        Args: {
          p_module_id: string
          p_module_name?: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      set_mait_intelliweb_sync_options: {
        Args: {
          p_auto_commit_enabled?: boolean
          p_auto_sync_enabled?: boolean
          p_module_id: string
          p_overlap_days?: number
          p_sync_kind: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      set_mait_intelliweb_weather_module: {
        Args: {
          p_module_id: string
          p_module_name?: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      set_manual_issue_status: {
        Args: { p_client_updated_at?: string; p_id: string; p_status: string }
        Returns: Json
      }
      set_my_operational_tool_preferences: {
        Args: {
          p_hidden_tool_ids?: string[]
          p_preference_version?: number
          p_visible_tool_ids: string[]
        }
        Returns: Json
      }
      set_pin_row_segments: {
        Args: { p_pin_id: string; p_segments: Json }
        Returns: Json
      }
      set_pruning_activity_resource: {
        Args: {
          p_activity_id: string
          p_external_resource_id?: string
          p_worker_user_id?: string
        }
        Returns: Json
      }
      set_pruning_activity_resource_cas: {
        Args: {
          p_activity_id: string
          p_expected_client_updated_at: string
          p_expected_external_resource_id: string
          p_expected_worker_user_id: string
          p_external_resource_id: string
          p_worker_user_id: string
        }
        Returns: Json
      }
      set_pruning_entry_work_task: {
        Args: { p_entry_id: string; p_work_task_id: string }
        Returns: undefined
      }
      set_system_admin_active: {
        Args: { p_is_active: boolean; p_user_id: string }
        Returns: {
          created_at: string
          created_by: string
          email: string
          is_active: boolean
          user_id: string
        }[]
      }
      set_system_feature_flag: {
        Args: { p_is_enabled: boolean; p_key: string; p_value?: Json }
        Returns: undefined
      }
      set_vineyard_current_observation_provider: {
        Args: { p_provider: string; p_vineyard_id: string }
        Returns: undefined
      }
      set_vineyard_custom_pin_type_active: {
        Args: { p_id: string; p_is_active: boolean }
        Returns: Json
      }
      set_vineyard_forecast_provider: {
        Args: { p_provider: string; p_vineyard_id: string }
        Returns: string
      }
      set_vineyard_location: {
        Args: {
          p_elevation_metres: number
          p_latitude: number
          p_longitude: number
          p_timezone: string
          p_vineyard_id: string
        }
        Returns: {
          elevation_metres: number
          latitude: number
          longitude: number
          timezone: string
          vineyard_id: string
        }[]
      }
      set_vineyard_recent_rain_lookback_hours: {
        Args: { p_hours: number; p_vineyard_id: string }
        Returns: number
      }
      set_vineyard_region_settings:
        | {
            Args: {
              p_area_unit: string
              p_country_code: string
              p_currency_code: string
              p_date_format: string
              p_distance_unit: string
              p_fuel_unit: string
              p_spray_rate_area_unit: string
              p_terminology_region: string
              p_timezone: string
              p_vineyard_id: string
              p_volume_unit: string
            }
            Returns: {
              area_unit: string
              country_code: string
              currency_code: string
              date_format: string
              distance_unit: string
              fuel_unit: string
              spray_rate_area_unit: string
              terminology_region: string
              timezone: string
              vineyard_id: string
              volume_unit: string
            }[]
          }
        | {
            Args: {
              p_area_unit: string
              p_country_code: string
              p_currency_code: string
              p_date_format: string
              p_distance_unit: string
              p_fuel_unit: string
              p_spray_rate_area_unit: string
              p_sugar_measurement_unit: string
              p_terminology_region: string
              p_timezone: string
              p_vineyard_id: string
              p_volume_unit: string
            }
            Returns: {
              area_unit: string
              country_code: string
              currency_code: string
              date_format: string
              distance_unit: string
              fuel_unit: string
              spray_rate_area_unit: string
              sugar_measurement_unit: string
              terminology_region: string
              timezone: string
              vineyard_id: string
              volume_unit: string
            }[]
          }
      set_vineyard_season_settings: {
        Args: {
          p_season_start_day: number
          p_season_start_month: number
          p_vineyard_id: string
        }
        Returns: {
          season_start_day: number
          season_start_month: number
          updated_at: string
          vineyard_id: string
        }[]
      }
      set_vineyard_spray_profile: {
        Args: {
          p_spray_carrier_volume_basis: string
          p_spray_compliance_profile: string
          p_vineyard_id: string
        }
        Returns: {
          country_code: string
          spray_carrier_volume_basis: string
          spray_compliance_profile: string
          vineyard_id: string
        }[]
      }
      set_vineyard_yield_sampling_settings: {
        Args: { p_samples_per_hectare: number; p_vineyard_id: string }
        Returns: {
          samples_per_hectare: number
          vineyard_id: string
        }[]
      }
      set_work_task_pruning_activity: {
        Args: { p_activity_id: string; p_work_task_id: string }
        Returns: undefined
      }
      soft_delete_damage_record: { Args: { p_id: string }; Returns: undefined }
      soft_delete_equipment_item: { Args: { p_id: string }; Returns: undefined }
      soft_delete_fertiliser_record: {
        Args: { p_id: string }
        Returns: undefined
      }
      soft_delete_fuel_purchase: { Args: { p_id: string }; Returns: undefined }
      soft_delete_grape_allocation: {
        Args: { p_id: string }
        Returns: undefined
      }
      soft_delete_grape_purchaser: {
        Args: { p_id: string }
        Returns: undefined
      }
      soft_delete_growth_stage_image: {
        Args: { p_image_id: string }
        Returns: undefined
      }
      soft_delete_growth_stage_record: {
        Args: { p_id: string }
        Returns: undefined
      }
      soft_delete_historical_yield_record: {
        Args: { p_id: string }
        Returns: undefined
      }
      soft_delete_maintenance_log: {
        Args: { p_id: string }
        Returns: undefined
      }
      soft_delete_operator_category: {
        Args: { p_id: string }
        Returns: undefined
      }
      soft_delete_paddock: {
        Args: { p_paddock_id: string }
        Returns: undefined
      }
      soft_delete_picking_record: { Args: { p_id: string }; Returns: undefined }
      soft_delete_pin: { Args: { p_pin_id: string }; Returns: undefined }
      soft_delete_pruning_activity_labour_line: {
        Args: { p_id: string }
        Returns: undefined
      }
      soft_delete_pruning_season: { Args: { p_id: string }; Returns: undefined }
      soft_delete_pruning_yield_settings: {
        Args: { p_id: string }
        Returns: undefined
      }
      soft_delete_resistance_plan: {
        Args: { p_id: string }
        Returns: undefined
      }
      soft_delete_saved_chemical: { Args: { p_id: string }; Returns: undefined }
      soft_delete_saved_chemicals: { Args: { p_id: string }; Returns: Json }
      soft_delete_saved_input: { Args: { p_id: string }; Returns: undefined }
      soft_delete_saved_spray_preset: {
        Args: { p_id: string }
        Returns: undefined
      }
      soft_delete_season_yield_estimate: {
        Args: { p_id: string }
        Returns: undefined
      }
      soft_delete_spray_equipment: {
        Args: { p_id: string }
        Returns: undefined
      }
      soft_delete_spray_record: {
        Args: { p_spray_record_id: string }
        Returns: undefined
      }
      soft_delete_tractor: { Args: { p_id: string }; Returns: undefined }
      soft_delete_tractor_fuel_log: {
        Args: { p_id: string }
        Returns: undefined
      }
      soft_delete_trip: { Args: { p_trip_id: string }; Returns: undefined }
      soft_delete_trip_cost_allocation: {
        Args: { p_id: string }
        Returns: undefined
      }
      soft_delete_trip_cost_allocations_for_trip: {
        Args: { p_trip_id: string }
        Returns: undefined
      }
      soft_delete_vineyard_machine: {
        Args: { p_id: string }
        Returns: undefined
      }
      soft_delete_vineyard_material: {
        Args: { p_id: string }
        Returns: undefined
      }
      soft_delete_vintage_note: { Args: { p_id: string }; Returns: boolean }
      soft_delete_work_task: { Args: { p_id: string }; Returns: undefined }
      soft_delete_work_task_labour_line: {
        Args: { p_id: string }
        Returns: undefined
      }
      soft_delete_work_task_machine_line: {
        Args: { p_id: string }
        Returns: undefined
      }
      soft_delete_work_task_material: {
        Args: { p_id: string }
        Returns: undefined
      }
      soft_delete_work_task_paddock: {
        Args: { p_id: string }
        Returns: undefined
      }
      soft_delete_work_task_piece_rate_row: {
        Args: { p_id: string }
        Returns: undefined
      }
      soft_delete_work_task_type: { Args: { p_id: string }; Returns: undefined }
      soft_delete_worker_type: { Args: { p_id: string }; Returns: undefined }
      soft_delete_yield_bunch_weight: {
        Args: { p_id: string }
        Returns: boolean
      }
      soft_delete_yield_estimation_session: {
        Args: { p_id: string }
        Returns: undefined
      }
      soil_analysis_apply_extraction: {
        Args: {
          p_document_id: string
          p_model: string
          p_parser_version: string
          p_raw_extraction: Json
          p_results: Json
          p_sample_id: string
          p_sample_patch: Json
        }
        Returns: Json
      }
      soil_analysis_map_report: {
        Args: {
          p_analyte_key: string
          p_as_of?: string
          p_method: string
          p_unit: string
          p_vineyard_id: string
        }
        Returns: {
          extraction_confidence: number
          lab_range_max: number
          lab_range_min: number
          lab_range_text: string
          lab_sample_id: string
          lab_status: string
          laboratory: string
          paddock_id: string
          paddock_name: string
          polygon_points: Json
          previous_sample_id: string
          previous_sampled_at: string
          previous_value_numeric: number
          sample_depth_from_cm: number
          sample_depth_to_cm: number
          sample_id: string
          sampled_at: string
          value_numeric: number
          value_text: string
        }[]
      }
      soil_analysis_report_series: {
        Args: { p_vineyard_id: string }
        Returns: {
          analyte_key: string
          analyte_name: string
          block_count: number
          category: string
          desired_direction: string
          first_sampled_at: string
          latest_sampled_at: string
          method: string
          sample_count: number
          unit: string
        }[]
      }
      soil_analysis_set_block_mappings: {
        Args: { p_mappings: Json; p_sample_id: string }
        Returns: Json
      }
      spray_actual_amendments_v1: { Args: { p_trip_id: string }; Returns: Json }
      spray_block_attribution_is_valid: {
        Args: { p_blocks: Json }
        Returns: boolean
      }
      spray_block_ids_are_valid: { Args: { p_ids: string[] }; Returns: boolean }
      spray_job_resistance_link_state: {
        Args: { p_job_id: string }
        Returns: string
      }
      spray_report_active_seconds_v1: {
        Args: {
          p_end: string
          p_pauses: Json
          p_resumes: Json
          p_start: string
        }
        Returns: number
      }
      spray_report_actual_chemical_totals_v1: {
        Args: { p_tanks: Json }
        Returns: Json
      }
      spray_report_planned_chemical_totals_v1: {
        Args: { p_tanks: Json }
        Returns: Json
      }
      spray_report_rows_v1: {
        Args: {
          p_blocks: Json
          p_trip: Database["public"]["Tables"]["trips"]["Row"]
        }
        Returns: Json
      }
      spray_report_safe_number_v1: {
        Args: { p_value: string }
        Returns: number
      }
      spray_report_tanks_v1: {
        Args: { p_planned: Json; p_trip_id: string }
        Returns: Json
      }
      spray_weather_missing_slots_v1: {
        Args: { p_through?: string; p_trip_id: string }
        Returns: {
          sample_slot: string
        }[]
      }
      stage_irrigation_import_rows: {
        Args: { p_batch_id: string; p_rows: Json }
        Returns: Json
      }
      start_chemical_v3_discovery: {
        Args: {
          p_country_code?: string
          p_input_kind?: string
          p_photo_path?: string
          p_query?: string
        }
        Returns: {
          job_id: string
          reused: boolean
          status: string
        }[]
      }
      start_chemical_v3_discovery_v2: {
        Args: {
          p_country_code?: string
          p_input_kind?: string
          p_photo_path?: string
          p_query?: string
          p_vineyard_id?: string
        }
        Returns: {
          job_id: string
          reused: boolean
          status: string
        }[]
      }
      storage_first_folder_uuid: { Args: { p_name: string }; Returns: string }
      submit_account_deletion_request: {
        Args: { p_reason?: string }
        Returns: Json
      }
      sync_pruning_activity_rollup: {
        Args: { p_activity_id: string }
        Returns: undefined
      }
      transfer_vineyard_ownership: {
        Args: {
          p_new_owner_id: string
          p_remove_old_owner?: boolean
          p_vineyard_id: string
        }
        Returns: Json
      }
      trip_cancellation_receipt_json_v1: {
        Args: {
          r: Database["public"]["Tables"]["trip_activity_cancellation_receipts"]["Row"]
        }
        Returns: Json
      }
      trip_occurrence_actor_uid_v1: { Args: never; Returns: string }
      update_irrigation_session: {
        Args: {
          p_calculation_method?: string
          p_clear_times?: boolean
          p_duration_minutes?: number
          p_finished_at?: string
          p_flow_litres_per_hour?: number
          p_id: string
          p_meter_finish_litres?: number
          p_meter_start_litres?: number
          p_notes?: string
          p_session_date?: string
          p_started_at?: string
          p_total_volume_litres?: number
          p_use_current_configuration?: boolean
        }
        Returns: Json
      }
      update_irrigation_system: {
        Args: {
          p_controller_name?: string
          p_controller_provider?: string
          p_external_controller_id?: string
          p_id: string
          p_is_active?: boolean
          p_name?: string
          p_notes?: string
          p_water_source?: string
        }
        Returns: Json
      }
      update_irrigation_valve: {
        Args: {
          p_clear_configured_flow?: boolean
          p_configured_flow_litres_per_hour?: number
          p_id: string
          p_is_active?: boolean
          p_measured_flow_litres_per_hour?: number
          p_name?: string
          p_notes?: string
          p_valve_number?: string
        }
        Returns: Json
      }
      update_manual_issue: {
        Args: {
          p_along_row_distance_m?: number
          p_assigned_user_id?: string
          p_category?: string
          p_client_updated_at?: string
          p_description?: string
          p_driving_row_number?: number
          p_due_date?: string
          p_id: string
          p_latitude?: number
          p_location_scope: string
          p_longitude?: number
          p_paddock_id?: string
          p_pin_row_number?: number
          p_pin_side?: string
          p_priority?: string
          p_segments?: Json
          p_snapped_latitude?: number
          p_snapped_longitude?: number
          p_snapped_to_row?: boolean
          p_title: string
        }
        Returns: Json
      }
      update_member_operator_category: {
        Args: {
          p_operator_category_id: string
          p_user_id: string
          p_vineyard_id: string
        }
        Returns: {
          display_name: string | null
          id: string
          joined_at: string
          role: string
          user_id: string
          vineyard_id: string
          worker_type_id: string | null
        }[]
        SetofOptions: {
          from: "*"
          to: "vineyard_members"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      update_member_role: {
        Args: { p_role: string; p_user_id: string; p_vineyard_id: string }
        Returns: {
          display_name: string | null
          id: string
          joined_at: string
          role: string
          user_id: string
          vineyard_id: string
          worker_type_id: string | null
        }[]
        SetofOptions: {
          from: "*"
          to: "vineyard_members"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      update_member_worker_type: {
        Args: {
          p_user_id: string
          p_vineyard_id: string
          p_worker_type_id: string
        }
        Returns: {
          display_name: string | null
          id: string
          joined_at: string
          role: string
          user_id: string
          vineyard_id: string
          worker_type_id: string | null
        }[]
        SetofOptions: {
          from: "*"
          to: "vineyard_members"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      update_pruning_activity: {
        Args: {
          p_activity: Json
          p_activity_id: string
          p_allocations: Json
          p_client_updated_at?: string
        }
        Returns: Json
      }
      update_pruning_entry: {
        Args: {
          p_clear_work_task?: boolean
          p_client_updated_at?: string
          p_entry_date: string
          p_entry_id: string
          p_estimated_vines?: number
          p_finish_time?: string
          p_labour_hours?: number
          p_method?: string
          p_notes?: string
          p_segments?: Json
          p_start_time?: string
          p_vintage_year?: number
          p_work_task_id?: string
          p_worker: string
        }
        Returns: Json
      }
      update_skipped_pruning_entry: {
        Args: {
          p_client_updated_at?: string
          p_entry_date: string
          p_entry_id: string
          p_notes?: string
          p_segments?: Json
        }
        Returns: Json
      }
      upsert_davis_rainfall_daily: {
        Args: {
          p_date: string
          p_rainfall_mm: number
          p_station_id: string
          p_station_name?: string
          p_vineyard_id: string
        }
        Returns: string
      }
      upsert_fertigation_application: {
        Args: {
          p_growth_stage_code: string
          p_id: string
          p_irrigation_session_id: string
          p_notes: string
          p_products: Json
          p_program_step_id: string
          p_program_step_name: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      upsert_irrigation_fertigation: {
        Args: {
          p_id: string
          p_irrigation_session_id: string
          p_notes?: string
          p_products?: Json
          p_program_step_id?: string
          p_vineyard_id: string
        }
        Returns: Json
      }
      upsert_manual_rainfall: {
        Args: {
          p_date: string
          p_notes?: string
          p_rainfall_mm: number
          p_vineyard_id: string
        }
        Returns: string
      }
      upsert_open_meteo_rainfall_daily: {
        Args: { p_date: string; p_rainfall_mm: number; p_vineyard_id: string }
        Returns: string
      }
      upsert_operator_category: {
        Args: { p_cost_per_hour: number; p_name: string; p_vineyard_id: string }
        Returns: {
          client_updated_at: string | null
          cost_per_hour: number
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          name: string
          sync_version: number
          updated_at: string
          updated_by: string | null
          vineyard_id: string
        }[]
        SetofOptions: {
          from: "*"
          to: "worker_types"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      upsert_paddock_soil_profile: {
        Args: {
          p_australian_soil_classification?: string
          p_australian_soil_classification_code?: string
          p_available_water_capacity_mm_per_m: number
          p_confidence?: string
          p_country_code?: string
          p_drainage_risk?: string
          p_effective_root_depth_m: number
          p_infiltration_risk?: string
          p_irrigation_soil_class: string
          p_is_manual_override?: boolean
          p_land_soil_capability?: string
          p_land_soil_capability_class?: number
          p_lookup_latitude?: number
          p_lookup_longitude?: number
          p_management_allowed_depletion_percent: number
          p_manual_notes?: string
          p_model_version?: string
          p_paddock_id: string
          p_raw_source_json?: Json
          p_region_code?: string
          p_soil_description?: string
          p_soil_landscape?: string
          p_soil_landscape_code?: string
          p_soil_texture_class?: string
          p_source?: string
          p_source_dataset?: string
          p_source_feature_id?: string
          p_source_name?: string
          p_source_provider?: string
          p_waterlogging_risk?: string
        }
        Returns: {
          australian_soil_classification: string | null
          australian_soil_classification_code: string | null
          available_water_capacity_mm_per_m: number | null
          confidence: string | null
          country_code: string | null
          created_at: string
          drainage_risk: string | null
          effective_root_depth_m: number | null
          id: string
          infiltration_risk: string | null
          irrigation_soil_class: string | null
          is_manual_override: boolean
          land_soil_capability: string | null
          land_soil_capability_class: number | null
          lookup_latitude: number | null
          lookup_longitude: number | null
          management_allowed_depletion_percent: number | null
          manual_notes: string | null
          model_version: string
          paddock_id: string | null
          raw_source_json: Json | null
          region_code: string | null
          soil_description: string | null
          soil_landscape: string | null
          soil_landscape_code: string | null
          soil_texture_class: string | null
          source: string
          source_dataset: string | null
          source_feature_id: string | null
          source_name: string | null
          source_provider: string | null
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          waterlogging_risk: string | null
        }[]
        SetofOptions: {
          from: "*"
          to: "paddock_soil_profiles"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      upsert_spray_tank_actual: {
        Args: {
          p_chemicals: Json
          p_client_updated_at: string
          p_confirmed_at: string
          p_id: string
          p_spray_record_id: string
          p_tank_number: number
          p_tank_session_id: string
          p_trip_id: string
          p_vineyard_id: string
          p_water_volume_l: number
        }
        Returns: {
          chemicals: Json
          client_updated_at: string
          confirmed_at: string
          confirmed_by: string
          correction_version: number
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          last_corrected_at: string | null
          spray_record_id: string
          sync_version: number
          tank_number: number
          tank_session_id: string
          trip_id: string
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          water_volume_l: number | null
        }
        SetofOptions: {
          from: "*"
          to: "spray_tank_actuals"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_vineyard_default_soil_profile: {
        Args: {
          p_australian_soil_classification?: string
          p_australian_soil_classification_code?: string
          p_available_water_capacity_mm_per_m: number
          p_confidence?: string
          p_country_code?: string
          p_drainage_risk?: string
          p_effective_root_depth_m: number
          p_infiltration_risk?: string
          p_irrigation_soil_class: string
          p_is_manual_override?: boolean
          p_land_soil_capability?: string
          p_land_soil_capability_class?: number
          p_lookup_latitude?: number
          p_lookup_longitude?: number
          p_management_allowed_depletion_percent: number
          p_manual_notes?: string
          p_model_version?: string
          p_raw_source_json?: Json
          p_region_code?: string
          p_soil_description?: string
          p_soil_landscape?: string
          p_soil_landscape_code?: string
          p_soil_texture_class?: string
          p_source?: string
          p_source_dataset?: string
          p_source_feature_id?: string
          p_source_name?: string
          p_source_provider?: string
          p_vineyard_id: string
          p_waterlogging_risk?: string
        }
        Returns: {
          australian_soil_classification: string | null
          australian_soil_classification_code: string | null
          available_water_capacity_mm_per_m: number | null
          confidence: string | null
          country_code: string | null
          created_at: string
          drainage_risk: string | null
          effective_root_depth_m: number | null
          id: string
          infiltration_risk: string | null
          irrigation_soil_class: string | null
          is_manual_override: boolean
          land_soil_capability: string | null
          land_soil_capability_class: number | null
          lookup_latitude: number | null
          lookup_longitude: number | null
          management_allowed_depletion_percent: number | null
          manual_notes: string | null
          model_version: string
          paddock_id: string | null
          raw_source_json: Json | null
          region_code: string | null
          soil_description: string | null
          soil_landscape: string | null
          soil_landscape_code: string | null
          soil_texture_class: string | null
          source: string
          source_dataset: string | null
          source_feature_id: string | null
          source_name: string | null
          source_provider: string | null
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          waterlogging_risk: string | null
        }[]
        SetofOptions: {
          from: "*"
          to: "paddock_soil_profiles"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      upsert_vineyard_forecast_cache: {
        Args: {
          p_payload: Json
          p_provider: string
          p_provider_location_ref: string
          p_provider_updated_at: string
          p_schema_version: string
          p_timezone: string
          p_ttl_minutes?: number
          p_vineyard_id: string
        }
        Returns: undefined
      }
      upsert_vineyard_grape_clone: {
        Args: {
          p_display_name: string
          p_is_active?: boolean
          p_variety_key: string
          p_vineyard_id: string
        }
        Returns: {
          clone_key: string
          created_at: string
          display_name: string
          id: string
          is_active: boolean
          is_custom: boolean
          updated_at: string
          variety_key: string
          vineyard_id: string
        }
        SetofOptions: {
          from: "*"
          to: "vineyard_grape_clones"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_vineyard_grape_variety: {
        Args: {
          p_display_name: string
          p_is_active?: boolean
          p_optimal_gdd_override?: number
          p_variety_key: string
          p_vineyard_id: string
        }
        Returns: {
          created_at: string
          display_name: string
          id: string
          is_active: boolean
          is_custom: boolean
          optimal_gdd_override: number | null
          updated_at: string
          variety_key: string
          vineyard_id: string
        }
        SetofOptions: {
          from: "*"
          to: "vineyard_grape_varieties"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_vineyard_rootstock: {
        Args: {
          p_display_name: string
          p_is_active?: boolean
          p_vineyard_id: string
        }
        Returns: {
          created_at: string
          display_name: string
          id: string
          is_active: boolean
          is_custom: boolean
          rootstock_key: string
          updated_at: string
          vineyard_id: string
        }
        SetofOptions: {
          from: "*"
          to: "vineyard_rootstocks"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_vintage_note: {
        Args: {
          p_client_updated_at?: string
          p_id: string
          p_note_date: string
          p_note_type_id?: string
          p_note_type_label?: string
          p_notes?: string
          p_observer_name?: string
          p_vineyard_id: string
        }
        Returns: {
          client_updated_at: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          note_date: string
          note_type_id: string | null
          note_type_label: string | null
          notes: string | null
          observed_by_user_id: string | null
          observer_name_snapshot: string | null
          sync_version: number
          updated_at: string
          updated_by: string | null
          vineyard_id: string
          vintage_year: number
        }
        SetofOptions: {
          from: "*"
          to: "vintage_notes"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_vintage_note_type: {
        Args: {
          p_code: string
          p_group_code: string
          p_id: string
          p_is_active?: boolean
          p_label: string
          p_sort_order?: number
          p_vineyard_id: string
        }
        Returns: {
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          group_code: string
          id: string
          is_active: boolean
          is_system: boolean
          label: string
          sort_order: number
          updated_at: string
          updated_by: string | null
          vineyard_id: string | null
        }
        SetofOptions: {
          from: "*"
          to: "vintage_note_types"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_worker_type: {
        Args: { p_cost_per_hour: number; p_name: string; p_vineyard_id: string }
        Returns: {
          client_updated_at: string | null
          cost_per_hour: number
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          name: string
          sync_version: number
          updated_at: string
          updated_by: string | null
          vineyard_id: string
        }[]
        SetofOptions: {
          from: "*"
          to: "worker_types"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      upsert_wunderground_rainfall_daily: {
        Args: {
          p_date: string
          p_rainfall_mm: number
          p_station_id: string
          p_station_name?: string
          p_vineyard_id: string
        }
        Returns: string
      }
      upsert_yield_bunch_weight: {
        Args: {
          p_bunch_weight_grams: number
          p_paddock_id: string
          p_variety_key: string
          p_variety_name: string
          p_vineyard_id: string
        }
        Returns: {
          base_revision: number | null
          bunch_weight_grams: number
          client_updated_at: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          paddock_id: string | null
          server_revision: number
          sync_version: number
          updated_at: string
          updated_by: string | null
          variety_key: string
          variety_name: string
          vineyard_id: string
        }
        SetofOptions: {
          from: "*"
          to: "yield_bunch_weights"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      validate_irrigation_configuration: {
        Args: { p_valve_id: string; p_vineyard_id: string }
        Returns: Json
      }
      validate_irrigation_import: {
        Args: {
          p_batch_id: string
          p_exclude_test_programs?: boolean
          p_threshold_litres?: number
          p_volume_comparison?: string
        }
        Returns: Json
      }
      validate_new_occurrence_geometry_v1: {
        Args: { item: Json; v: string }
        Returns: undefined
      }
      validate_occurrence_setup_links_v1: {
        Args: { setup: Json; v: string }
        Returns: undefined
      }
      validate_spray_tank_actual_chemicals: {
        Args: { p_chemicals: Json }
        Returns: boolean
      }
      validate_spray_tank_actual_chemicals_v1: {
        Args: { p_chemicals: Json; p_planned_tank: Json; p_vineyard_id: string }
        Returns: boolean
      }
      validate_trip_occurrences_v1: {
        Args: { d: Json; v_vineyard: string }
        Returns: undefined
      }
      verify_grape_variety_catalog: {
        Args: never
        Returns: {
          active_builtin_count: number
          inactive_builtin_count: number
          last_updated_at: string
          pinot_grigio_resolves_to_pinot_gris: boolean
          pinot_gris_active: boolean
          total_aliases: number
          total_count: number
        }[]
      }
      verify_pruning_season_enforcement: { Args: never; Returns: Json }
      vineyard_member_role: { Args: { p_vineyard_id: string }; Returns: string }
      vineyard_role: { Args: { p_vineyard_id: string }; Returns: string }
      vineyard_spray_target_json: {
        Args: {
          t: Database["public"]["Tables"]["vineyard_spray_targets"]["Row"]
        }
        Returns: Json
      }
      vintage_report_abandon: {
        Args: {
          p_author_id: string
          p_input: Json
          p_operation_id: string
          p_vineyard_id: string
          p_vintage: number
        }
        Returns: Json
      }
      vintage_report_command: {
        Args: {
          p_author_id?: string
          p_before_revision?: number
          p_command: string
          p_content?: Json
          p_expected_revision_id?: string
          p_offset?: number
          p_operation_id?: string
          p_report_through?: string
          p_vineyard_id: string
          p_vintage: number
        }
        Returns: Json
      }
      vintage_report_worker: {
        Args: {
          p_author: string
          p_command: string
          p_content?: Json
          p_error?: string
          p_operation_id: string
        }
        Returns: Json
      }
      vt_display_chemical_name: { Args: { raw: string }; Returns: string }
      vt_equipment_integrity_report: {
        Args: never
        Returns: {
          check_name: string
          offending_count: number
          sample_ids: string[]
          severity: string
        }[]
      }
      vt_fertigation_can_access: {
        Args: { p_vineyard_id: string }
        Returns: boolean
      }
      vt_fertigation_json: {
        Args: {
          p_app: Database["public"]["Tables"]["fertigation_applications"]["Row"]
        }
        Returns: Json
      }
      vt_pbf_angle_diff: { Args: { a: number; b: number }; Returns: number }
      vt_pbf_authorized: { Args: { p_vineyard: string }; Returns: boolean }
      vt_pbf_bearing: {
        Args: { a_lat: number; a_lon: number; b_lat: number; b_lon: number }
        Returns: number
      }
      vt_pbf_bounding: {
        Args: { p_lat: number; p_lon: number; p_rows: Json }
        Returns: Json
      }
      vt_pbf_check_item: {
        Args: { it: Json; p_vineyard: string }
        Returns: Json
      }
      vt_pbf_check_item_base: {
        Args: { it: Json; p_vineyard: string }
        Returns: Json
      }
      vt_pbf_geometry_identity: {
        Args: { p_polygon: Json; p_rows: Json }
        Returns: string
      }
      vt_pbf_metres: {
        Args: { a_lat: number; a_lon: number; b_lat: number; b_lon: number }
        Returns: number
      }
      vt_pbf_norm_side: { Args: { v: string }; Returns: string }
      vt_pbf_point_in_polygon: {
        Args: { p_lat: number; p_lon: number; p_poly: Json }
        Returns: boolean
      }
      vt_pbf_project: {
        Args: { p_lat: number; p_lon: number; p_row: number; p_rows: Json }
        Returns: Json
      }
      vt_pbf_pt: { Args: { p: Json }; Returns: Record<string, unknown> }
      vt_pbf_reconstruct_pin: { Args: { p_pin: string }; Returns: Json }
      vt_pbf_rows: { Args: { p_rows: Json }; Returns: Json }
      vt_pbf_travel_obs: { Args: { p_obs: Json }; Returns: Json }
      vt_pbf_travel_track: {
        Args: { p_lat: number; p_lon: number; p_path: Json }
        Returns: Json
      }
      vt_pbf_validation: { Args: { p_vineyard: string }; Returns: Json }
      work_task_effective_labour_cost: {
        Args: { p_work_task_id: string }
        Returns: number
      }
      work_task_labour_cost_source: {
        Args: { p_work_task_id: string }
        Returns: string
      }
      work_task_labour_line_cost: {
        Args: { p_work_task_id: string }
        Returns: number
      }
      work_task_pruning_labour_line_cost: {
        Args: { p_work_task_id: string }
        Returns: number
      }
      worker_type_normalised_name: { Args: { p_name: string }; Returns: string }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {},
  },
} as const
