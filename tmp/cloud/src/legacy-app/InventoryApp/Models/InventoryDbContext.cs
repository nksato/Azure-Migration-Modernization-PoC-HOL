using System.Data.Entity;

namespace InventoryApp.Models
{
    public class InventoryDbContext : DbContext
    {
        public InventoryDbContext() : base("name=InventoryDb")
        {
        }

        public DbSet<Product> Products { get; set; }
    }
}
