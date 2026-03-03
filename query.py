#!/usr/bin/env python3
"""
Query interface for the Disease Knowledge Graph
Search diseases and content using semantic similarity
"""

import chromadb
from chromadb.config import Settings
from sentence_transformers import SentenceTransformer
import torch
from typing import List, Dict, Optional
import json

############################################################
# CONFIGURATION
############################################################

CONFIG = {
    "embedding_model": "intfloat/multilingual-e5-base",
    "device": "cuda" if torch.cuda.is_available() else "cpu",
    "chroma_path": "./chroma_db",
}

############################################################
# QUERY ENGINE
############################################################

class DiseaseQueryEngine:
    """Search and retrieve disease information."""
    
    def __init__(self, chroma_path: str = CONFIG["chroma_path"]):
        # Load embedding model
        print("Loading embedding model...")
        self.model = SentenceTransformer(
            CONFIG["embedding_model"],
            device=CONFIG["device"]
        )
        
        # Connect to ChromaDB
        print(f"Connecting to ChromaDB at {chroma_path}...")
        self.client = chromadb.PersistentClient(
            path=chroma_path,
            settings=Settings(anonymized_telemetry=False)
        )
        
        # Load collections
        try:
            self.journals = self.client.get_collection("journals")
            self.diseases = self.client.get_collection("diseases")
            self.contents = self.client.get_collection("contents")
            print("Successfully loaded all collections")
        except Exception as e:
            print(f"Error loading collections: {e}")
            raise
    
    def embed_query(self, query_text: str) -> List[float]:
        """Embed query text for similarity search."""
        prefixed_query = f"query: {query_text}"
        embedding = self.model.encode(
            prefixed_query,
            convert_to_tensor=False,
            normalize_embeddings=True
        )
        return embedding.tolist()
    
    def search_diseases(self, query: str, n_results: int = 5) -> Dict:
        """
        Search for diseases by name or description.
        
        Args:
            query: Search query (Indonesian or English)
            n_results: Number of results to return
            
        Returns:
            Dictionary with disease results
        """
        print(f"\nSearching diseases for: '{query}'")
        
        query_embedding = self.embed_query(query)
        
        results = self.diseases.query(
            query_embeddings=[query_embedding],
            n_results=n_results,
            include=["documents", "metadatas", "distances"]
        )
        
        # Format results
        formatted_results = []
        for i in range(len(results['ids'][0])):
            formatted_results.append({
                "disease_id": results['ids'][0][i],
                "name_id": results['metadatas'][0][i].get('name_id'),
                "name_en": results['metadatas'][0][i].get('name_en'),
                "page": results['metadatas'][0][i].get('page'),
                "similarity": 1 - results['distances'][0][i],  # Convert distance to similarity
                "document": results['documents'][0][i]
            })
        
        return {
            "query": query,
            "n_results": len(formatted_results),
            "results": formatted_results
        }
    
    def search_content(self, query: str, content_type: Optional[str] = None, 
                      n_results: int = 5) -> Dict:
        """
        Search for content (symptoms, transmission, control, etc.)
        
        Args:
            query: Search query
            content_type: Filter by type (definition, transmission, symptoms, control)
            n_results: Number of results to return
            
        Returns:
            Dictionary with content results
        """
        print(f"\nSearching content for: '{query}'")
        if content_type:
            print(f"  Filtering by type: {content_type}")
        
        query_embedding = self.embed_query(query)
        
        # Build where clause for filtering
        where = {}
        if content_type:
            where["content_type"] = content_type
        
        results = self.contents.query(
            query_embeddings=[query_embedding],
            n_results=n_results,
            where=where if where else None,
            include=["documents", "metadatas", "distances"]
        )
        
        # Format results
        formatted_results = []
        for i in range(len(results['ids'][0])):
            formatted_results.append({
                "content_id": results['ids'][0][i],
                "disease_id": results['metadatas'][0][i].get('disease_id'),
                "content_type": results['metadatas'][0][i].get('content_type'),
                "page_range": (
                    results['metadatas'][0][i].get('page_start'),
                    results['metadatas'][0][i].get('page_end')
                ),
                "similarity": 1 - results['distances'][0][i],
                "text": results['documents'][0][i][:300] + "..." if len(results['documents'][0][i]) > 300 else results['documents'][0][i]
            })
        
        return {
            "query": query,
            "content_type": content_type,
            "n_results": len(formatted_results),
            "results": formatted_results
        }
    
    def get_disease_info(self, disease_id: str) -> Dict:
        """
        Get all information about a specific disease.
        
        Args:
            disease_id: Disease ID
            
        Returns:
            Complete disease information with all content
        """
        # Get disease details
        disease = self.diseases.get(
            ids=[disease_id],
            include=["documents", "metadatas"]
        )
        
        if not disease['ids']:
            return {"error": "Disease not found"}
        
        # Get all content for this disease
        content_results = self.contents.get(
            where={"disease_id": disease_id},
            include=["documents", "metadatas"]
        )
        
        # Organize content by type
        content_by_type = {}
        for i in range(len(content_results['ids'])):
            ctype = content_results['metadatas'][i].get('content_type', 'other')
            if ctype not in content_by_type:
                content_by_type[ctype] = []
            
            content_by_type[ctype].append({
                "content_id": content_results['ids'][i],
                "text": content_results['documents'][i],
                "page_range": (
                    content_results['metadatas'][i].get('page_start'),
                    content_results['metadatas'][i].get('page_end')
                )
            })
        
        return {
            "disease_id": disease_id,
            "name_id": disease['metadatas'][0].get('name_id'),
            "name_en": disease['metadatas'][0].get('name_en'),
            "page": disease['metadatas'][0].get('page'),
            "content": content_by_type
        }
    
    def get_collection_stats(self) -> Dict:
        """Get statistics about the collections."""
        return {
            "journals": self.journals.count(),
            "diseases": self.diseases.count(),
            "contents": self.contents.count()
        }

############################################################
# INTERACTIVE CLI
############################################################

def interactive_query():
    """Interactive command-line interface for querying."""
    print("\n" + "="*60)
    print("Disease Knowledge Graph - Query Interface")
    print("="*60)
    
    # Initialize engine
    engine = DiseaseQueryEngine()
    
    # Show stats
    stats = engine.get_collection_stats()
    print(f"\nDatabase Statistics:")
    print(f"  Journals: {stats['journals']}")
    print(f"  Diseases: {stats['diseases']}")
    print(f"  Content Nodes: {stats['contents']}")
    
    # Interactive loop
    print("\nCommands:")
    print("  search <query>           - Search for diseases")
    print("  content <query>          - Search content (all types)")
    print("  symptoms <query>         - Search symptoms only")
    print("  control <query>          - Search control methods only")
    print("  transmission <query>     - Search transmission info only")
    print("  definition <query>       - Search definitions only")
    print("  info <disease_id>        - Get complete disease info")
    print("  quit                     - Exit")
    
    while True:
        try:
            user_input = input("\n> ").strip()
            
            if not user_input:
                continue
            
            parts = user_input.split(maxsplit=1)
            command = parts[0].lower()
            
            if command == "quit":
                print("Goodbye!")
                break
            
            if len(parts) < 2:
                print("Please provide a query or ID")
                continue
            
            query = parts[1]
            
            if command == "search":
                results = engine.search_diseases(query)
                print(f"\nFound {results['n_results']} diseases:")
                for r in results['results']:
                    print(f"\n  {r['name_id']} ({r['name_en']})")
                    print(f"    ID: {r['disease_id']}")
                    print(f"    Page: {r['page']}")
                    print(f"    Similarity: {r['similarity']:.3f}")
            
            elif command == "content":
                results = engine.search_content(query)
                print(f"\nFound {results['n_results']} content nodes:")
                for r in results['results']:
                    print(f"\n  Type: {r['content_type']}")
                    print(f"    Pages: {r['page_range']}")
                    print(f"    Similarity: {r['similarity']:.3f}")
                    print(f"    Text: {r['text']}")
            
            elif command in ["symptoms", "control", "transmission", "definition"]:
                results = engine.search_content(query, content_type=command)
                print(f"\nFound {results['n_results']} {command} entries:")
                for r in results['results']:
                    print(f"\n  Pages: {r['page_range']}")
                    print(f"    Similarity: {r['similarity']:.3f}")
                    print(f"    Text: {r['text']}")
            
            elif command == "info":
                disease_id = query
                info = engine.get_disease_info(disease_id)
                
                if "error" in info:
                    print(f"  {info['error']}")
                else:
                    print(f"\nDisease: {info['name_id']} ({info['name_en']})")
                    print(f"ID: {info['disease_id']}")
                    print(f"Page: {info['page']}")
                    print("\nContent:")
                    for ctype, contents in info['content'].items():
                        print(f"\n  {ctype.upper()}:")
                        for c in contents:
                            print(f"    - {c['text'][:200]}...")
            
            else:
                print(f"Unknown command: {command}")
        
        except KeyboardInterrupt:
            print("\n\nGoodbye!")
            break
        except Exception as e:
            print(f"Error: {e}")

############################################################
# MAIN
############################################################

def main():
    """Run interactive query interface."""
    import argparse
    
    parser = argparse.ArgumentParser(
        description="Query the Disease Knowledge Graph"
    )
    parser.add_argument(
        "--chroma",
        default=CONFIG["chroma_path"],
        help="Path to ChromaDB persistence directory"
    )
    parser.add_argument(
        "--query",
        help="Run a single query and exit"
    )
    parser.add_argument(
        "--type",
        choices=["disease", "content", "symptoms", "control", "transmission", "definition"],
        default="disease",
        help="Query type"
    )
    
    args = parser.parse_args()
    CONFIG["chroma_path"] = args.chroma
    
    if args.query:
        # Single query mode
        engine = DiseaseQueryEngine()
        
        if args.type == "disease":
            results = engine.search_diseases(args.query)
        else:
            content_type = None if args.type == "content" else args.type
            results = engine.search_content(args.query, content_type=content_type)
        
        print(json.dumps(results, indent=2, ensure_ascii=False))
    else:
        # Interactive mode
        interactive_query()

if __name__ == "__main__":
    main()