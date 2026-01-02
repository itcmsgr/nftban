// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2025 Antonios Voulvoulis <contact@nftban.com>

package webapi

// ContextKey is a custom type for context keys to avoid collisions
type ContextKey string

const (
	// ContextKeyUsername is the context key for storing username
	ContextKeyUsername ContextKey = "username"
	// ContextKeyRole is the context key for storing user role
	ContextKeyRole ContextKey = "role"
)
