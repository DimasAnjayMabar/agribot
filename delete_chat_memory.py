import chromadb
import os

def delete_memory_collection():
    # Pastikan path ini sama dengan yang ada di RAGPipeline kamu
    db_path = "./chroma_db"
    
    if not os.path.exists(db_path):
        print(f"Directory {db_path} tidak ditemukan.")
        return

    # Inisialisasi Client
    client = chromadb.PersistentClient(path=db_path)
    
    try:
        # Cek daftar collection yang ada
        existing_collections = [c.name for c in client.list_collections()]
        print(f"Collection saat ini: {existing_collections}")
        
        if "chat_memory" in existing_collections:
            print("Menghapus collection 'chat_memory'...")
            client.delete_collection(name="chat_memory")
            print("Berhasil dihapus!")
        else:
            print("Collection 'chat_memory' memang tidak ada.")
            
    except Exception as e:
        print(f"Terjadi kesalahan: {e}")

if __name__ == "__main__":
    delete_memory_collection()